import {randomUUID} from 'node:crypto';
import {createAutomationStore} from './store.mjs';
import {createCubbyClient,fetchLeaseFacts,IntegrationError} from './cubby.mjs';
import {evaluateNotification,digest,renderMessage} from './policy.mjs';
export function readiness(env){const missing=[];
 for(const [key,code] of [['CUBBY_API_KEY','cubby_credentials_missing'],['CUBBY_ORGANIZATION_ID','cubby_organization_missing']])if(!env[key])missing.push(code);
 if(env.CUBBY_OPERATIONAL_ACCESS_VERIFIED!=='true')missing.push('cubby_api_permissions_unverified');
 if(env.CUBBY_RATE_LIMIT_VERIFIED!=='true')missing.push('cubby_rate_limits_unverified');
 return {ready:missing.length===0,missing,targetIntervalSeconds:60,webhookConfigured:env.CUBBY_WEBHOOK_AUTH_CONFIRMED==='true',smsDispatchEnabled:env.LOCKS_LIVE_SMS_ENABLED==='true',templateVersion:'2026-11-05-draft-1'};
}
export function runtime(env=process.env,overrides={}){
 return {env,store:overrides.store||createAutomationStore({url:env.NEXT_PUBLIC_SUPABASE_URL,key:env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,workerToken:env.LOCKS_WORKER_TOKEN}),client:overrides.client||createCubbyClient({apiKey:env.CUBBY_API_KEY,limit:Math.min(500,Number(env.CUBBY_MAX_REQUESTS_PER_TICK)||120)}),...overrides};
}
function safeCode(error){return error instanceof IntegrationError?error.code:['automation_store_unreachable','automation_store_rejected'].includes(error?.message)?error.message:'automation_processing_failed'}
export async function processReference(rt,reference,{eventType='poll',occurredAt=null,evaluate=true}={}){
 if(evaluate&&!(await rt.store.call('baseline_ready')))throw new IntegrationError('baseline_not_ready');
 const previous=await rt.store.call('snapshot_get',{leaseId:reference.leaseId});
 const record=await fetchLeaseFacts(rt.client,reference,{previous,eventType,occurredAt,contractVerified:rt.env.CUBBY_OPERATIONAL_ACCESS_VERIFIED==='true'});
 await rt.store.call('snapshot_save',{...record,orgId:rt.env.CUBBY_ORGANIZATION_ID});
 if(!evaluate||!record.kind)return {state:'observed'};
 const context=await rt.store.call('context',{leaseId:reference.leaseId});
 const decision=evaluateNotification({kind:record.kind,facts:record.facts,assignments:context?.assignments,recipient:record.recipient,consent:context?.consent,policy:context?.policy});
 if(!decision.eligible){if(!['historical_event','payment_not_cleared','rental_not_ready','clearance_transition_unverified'].includes(decision.reason))await rt.store.call('exception',{orgId:rt.env.CUBBY_ORGANIZATION_ID,facilityId:reference.facilityId,key:digest([reference.leaseId,record.kind,record.facts.episodeId,decision.reason].join(':')),reason:decision.reason});return {state:'blocked',reason:decision.reason};}
 return await rt.store.call('enqueue',{...decision,leaseId:reference.leaseId,episodeId:record.facts.episodeId,consentId:context.consent.proofId})||{state:'blocked',reason:'database_guard'};
}
export async function drainInbox(rt,{id=null,limit=8}={}){
 if(!readiness(rt.env).ready)return {processed:0,blocked:'integration_not_ready'};
 let processed=0;const notificationIds=[];
 for(let i=0;i<limit;i++){
  const owner=randomUUID();const job=await rt.store.call('inbox_claim',{owner,...(id?{id}:{})});if(!job)break;
  try{const result=await processReference(rt,job.reference,{eventType:job.eventType,occurredAt:job.occurredAt});if(result?.id)notificationIds.push(result.id);await rt.store.call('inbox_finish',{id:job.id,owner,ok:true});processed++;}
  catch(error){await rt.store.call('inbox_finish',{id:job.id,owner,ok:false,errorCode:safeCode(error)});}
  if(id)break;
 }
 return {processed,notificationIds};
}
function assertArray(data,name){if(!Array.isArray(data[name])||data[name].length>=1000)throw new IntegrationError('cubby_completeness_unverified');return data[name]}
export async function pollOperationalData(rt){
 const owner=randomUUID();const claim=await rt.store.call('sync_claim',{owner});if(!claim)return {state:'already_running'};
 const cursors={...claim.cursors};let queued=0;
 try{
  const links=await rt.store.call('links');if(!links.length)throw new IntegrationError('facility_mapping_missing');
  for(const link of links){
   if(link.orgId!==rt.env.CUBBY_ORGANIZATION_ID)throw new IntegrationError('organization_mapping_mismatch');
   const source=link.sourceFacilityId;const prior=cursors[source];const before=new Date().toISOString();
   const after=prior?.leaseAfter?new Date(Date.parse(prior.leaseAfter)-120000).toISOString():null;
   const customerAfter=prior?.customerAfter?new Date(Date.parse(prior.customerAfter)-120000).toISOString():null;
   const [unitData,leaseData,customerData]=await Promise.all([
    rt.client.search('units/search',{facilityId:source}),rt.client.search('leases/search',{facilityId:source,...(after?{updatedAfter:after,updatedBefore:before}:{})}),
    rt.client.search('customers/search',{facilityId:source,...(customerAfter?{updatedAfter:customerAfter,updatedBefore:before}:{})},['leases'])
   ]);
   const units=assertArray(unitData,'units');const leases=assertArray(leaseData,'leases');const customers=assertArray(customerData,'customers');
   if(units.some(u=>u.facilityId!==source||!u.unitId||!u.name))throw new IntegrationError('unit_identity_invalid');
   await rt.store.call('units_save',{orgId:link.orgId,units:units.map(u=>({unitId:u.unitId,facilityId:u.facilityId,name:u.name,operationalState:{leaseId:u.leaseId??null,free:typeof u.free==='boolean'?u.free:null,reserved:typeof u.reserved==='boolean'?u.reserved:null,overlocked:typeof u.overlocked==='boolean'?u.overlocked:null,rentable:typeof u.rentability?.rentable==='boolean'?u.rentability.rentable:null,unrentableReason:u.rentability?.unrentableReason||null}}))});
   for(const lease of leases){
    if(!lease.leaseId||!lease.unitId||!lease.customerId||lease.facilityId!==source)throw new IntegrationError('lease_identity_invalid');
    const reference={leaseId:lease.leaseId,facilityId:source,unitId:lease.unitId,customerId:lease.customerId};
    if(!prior?.baseline){
     const unit=units.find(u=>u.unitId===lease.unitId);
     await rt.store.call('snapshot_save',{orgId:link.orgId,sourceVersion:lease.updatedAt||null,unitLabel:unit?.name||null,recipient:{phone:null,suppressed:null},facts:{...reference,verified:false,verifiedAt:before,occurredAt:lease.updatedAt||before,active:unit?.leaseId===lease.leaseId&&lease.moveOutDate==null,overlockNeeded:typeof lease.overlockNeeded==='boolean'?lease.overlockNeeded:null,blockedEpisode:lease.overlockNeeded===true?digest([lease.leaseId,lease.updatedAt,'blocked'].join(':')):null}});
    }else{
     await rt.store.call('inbox_accept',{key:digest(['lease',lease.leaseId,lease.updatedAt].join(':')),eventType:'lease_changed',reference,occurredAt:lease.updatedAt||before});queued++;
    }
   }
   if(prior?.baseline)for(const customer of customers){
    const refs=await rt.store.call('references_for_customer',{orgId:link.orgId,customerId:customer.customerId});
    for(const reference of refs){await rt.store.call('inbox_accept',{key:digest(['customer',customer.customerId,customer.updatedAt,reference.leaseId].join(':')),eventType:'lease_changed',reference,occurredAt:customer.updatedAt||before});queued++;}
   }
   cursors[source]={leaseAfter:before,customerAfter:before,baseline:true};
  }
  await rt.store.call('sync_finish',{owner,ok:true,cursors});return {state:'synchronized',queued};
 }catch(error){await rt.store.call('sync_finish',{owner,ok:false,errorCode:safeCode(error)});return {state:'failed',reason:safeCode(error)};}
}
export async function drainOutbox(rt,{limit=4,id=null}={}){
 if(rt.env.LOCKS_LIVE_SMS_ENABLED!=='true')return {state:'disabled',sent:0};
 if(!readiness(rt.env).ready||!rt.sender?.ready())return {state:'blocked',sent:0};
 let sent=0;
 for(let i=0;i<limit;i++){
  const pending=await rt.store.call('outbox_peek',id?{id}:{});if(!pending)break;
  try{await processReference(rt,pending,{evaluate:false});}catch{return {state:'fresh_verification_failed',sent};}
  const message=await rt.store.call('outbox_claim',{id:pending.id});if(!message)break;if(message.cancelled)continue;
  let result;
  try{
   // The final database claim rechecks current assignment, phone, consent, evidence and both live-approval latches.
   const body=renderMessage(message.kind,{facility:message.facility,unit:message.unit,serial:message.serial,combination:message.combination,returnInstructions:message.returnInstructions});
   result=await rt.sender.send({phone:message.phone,body,attemptId:message.attemptId});
  }catch(error){result={state:'unknown',errorCode:'provider_outcome_unknown'};}
  // Never retain or log the secret-bearing message object or provider request/response bodies.
  await rt.store.call('outbox_result',{attemptId:message.attemptId,providerSid:result.sid||null,state:result.state,errorCode:result.errorCode||null});
  if(result.sid)sent++;
 }
 return {sent};
}
export async function runTick(rt){
 const ready=readiness(rt.env);await rt.store.call('heartbeat',ready);
 if(!ready.ready)return {state:'configuration_required',missing:ready.missing};
 const sync=await pollOperationalData(rt);const inbox=await drainInbox(rt);const outbox=await drainOutbox(rt);
 return {sync,inbox,outbox};
}
