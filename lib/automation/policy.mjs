import {createHash} from 'node:crypto';
export const TEMPLATE_VERSION='2026-11-05-draft-1';
export function normalizePhone(value){
 const raw=String(value||'').trim();const digits=raw.replace(/\D/g,'');
 if(raw.startsWith('+')&&/^[1-9]\d{7,14}$/.test(digits))return '+'+digits;
 if(digits.length===10)return '+1'+digits;
 if(digits.length===11&&digits.startsWith('1'))return '+'+digits;
 return null;
}
export function digest(value){return createHash('sha256').update(String(value)).digest('hex')}
export function notificationKey(kind,leaseId,assignmentId,episode){return digest(JSON.stringify([kind,leaseId,episode]))}
export function evaluateNotification({kind,facts,assignments,recipient,consent,policy,now=Date.now()}){
 const deny=reason=>({eligible:false,reason});
 if(!['overlock_clearance','new_rental'].includes(kind))return deny('unsupported_event');
 if(!policy?.evaluationStartedAt||!Number.isFinite(Date.parse(facts?.occurredAt))||Date.parse(facts.occurredAt)<Date.parse(policy.evaluationStartedAt))return deny('historical_event');
 const verified=Date.parse(facts?.verifiedAt);const age=now-verified;
 if(facts?.verified!==true||!Number.isFinite(age)||age< -5000||age>(policy.maxAgeSeconds||120)*1000)return deny('stale_or_unverified');
 if(facts.active!==true||facts.facilityId==null||facts.unitId==null||facts.leaseId==null||facts.customerId==null)return deny('lease_not_current');
 if(facts.auctionClear!==true||facts.restrictionsClear!==true)return deny('access_restriction');
 if(facts.paymentClear!==true||facts.overlockNeeded!==false)return deny('payment_not_cleared');
 if(kind==='new_rental'&&(facts.rentalCompleted!==true||facts.requirementsSatisfied!==true||facts.moveInAllowed!==true))return deny('rental_not_ready');
 if(kind==='overlock_clearance'&&facts.clearanceTransition!==true)return deny('clearance_transition_unverified');
 const matching=(assignments||[]).filter(a=>a.releasedAt==null&&a.facilityId===facts.facilityId&&a.unitId===facts.unitId);
 if(matching.some(a=>a.type==='auction'))return deny('auction_assignment');
 const type=kind==='overlock_clearance'?'overlock':'vacant';
 if(matching.length===0)return deny('missing_assignment');
 if(matching.length!==1||matching[0].type!==type)return deny('conflicting_assignment');
 const assignment=matching[0];
 if(assignment.lockStatus!==type||!assignment.id||!assignment.lockId||!Number.isInteger(assignment.lockVersion))return deny('assignment_changed');
 if(!Number.isFinite(Date.parse(assignment.assignedAt))||Date.parse(assignment.assignedAt)>Date.parse(facts.occurredAt))return deny('assignment_changed');
 const phone=normalizePhone(recipient?.phone);
 if(!phone||recipient?.customerId!==facts.customerId||recipient?.verified!==true)return deny('recipient_unverified');
 if(recipient.suppressed!==false||consent?.suppressed===true)return deny('sms_suppressed');
 if(consent?.customerId!==facts.customerId||consent?.phone!==phone||consent?.purpose!=='lock_access'||!consent?.proofId||consent?.valid!==true)return deny('consent_unverified');
 if(!facts.episodeId)return deny('episode_missing');
 return {eligible:true,reason:'eligible',key:notificationKey(kind,facts.leaseId,assignment.id,facts.episodeId),assignmentId:assignment.id,lockId:assignment.lockId,lockVersion:assignment.lockVersion,phone,customerId:facts.customerId,kind,templateVersion:TEMPLATE_VERSION};
}
export function renderMessage(kind,{facility,unit,serial,combination,returnInstructions}){
 if(!facility||!unit||!serial||!combination||!returnInstructions)throw new Error('template_fields_missing');
 const lead=kind==='overlock_clearance'?'Your unit is cleared for overlock removal.':kind==='new_rental'?'Your rental is ready.':null;
 if(!lead)throw new Error('unsupported_template');
 return `${facility} / My Storage Locks: ${lead} Unit ${unit}, lock ${serial}, combination ${combination}. Please return our lock to ${returnInstructions}. Reply STOP to opt out; HELP for help.`;
}
export function transitionDelivery(current,incoming){
 const states=['accepted','queued','sending','sent','delivered','undelivered','failed'];
 if(!states.includes(incoming))return current;
 if(current==='delivered')return current;
 if(['failed','undelivered'].includes(current)&&incoming!=='delivered')return current;
 if(['delivered','failed','undelivered'].includes(incoming))return incoming;
 return states.indexOf(incoming)>states.indexOf(current)?incoming:current;
}
export function eventReference(payload){
 const lease=payload?.lease;const unit=payload?.unit;const facility=payload?.facility;
 if(!lease?.leaseId||!lease?.unitId||!lease?.facilityId||!lease?.customerId)return null;
 if(unit?.unitId&&unit.unitId!==lease.unitId)return null;
 if(facility?.facilityId&&facility.facilityId!==lease.facilityId)return null;
 return {leaseId:lease.leaseId,unitId:lease.unitId,facilityId:lease.facilityId,customerId:lease.customerId};
}
