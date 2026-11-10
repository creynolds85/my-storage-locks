import {createCubbyClient,fetchLeaseFacts,IntegrationError} from './cubby.mjs';
import {evaluateNotification,TEMPLATE_VERSION} from './policy.mjs';

// Worker-authenticated, bounded observation only. No inbox/outbox, secret retrieval,
// consent promotion, assignment mapping, provider submission or database writes.
/** @param {any} env @param {{store:any,samples?:any[],client?:any}} options */
export async function verifyPreactivation(env,{store,samples=[],client=createCubbyClient({apiKey:env.CUBBY_API_KEY,limit:60})}={}){
 const started=Date.now();
 if(env.LOCKS_LIVE_SMS_ENABLED==='true')return {state:'blocked',reason:'dry_run_required'};
 if(!Array.isArray(samples)||samples.length<1||samples.length>6)return {state:'blocked',reason:'invalid_sample_count'};
 const links=await store.call('links');
 const allowed=new Set(links.filter(l=>l.orgId===env.CUBBY_ORGANIZATION_ID).map(l=>l.sourceFacilityId));
 const results=[];
 for(const sample of samples){
  const reference=sample?.reference;
  if(!reference||!allowed.has(reference.facilityId)||!['leaseId','unitId','customerId','facilityId'].every(k=>typeof reference[k]==='string'&&reference[k].length<160)){
   results.push({state:'blocked',reason:'sample_scope_invalid'});continue;
  }
  const begin=Date.now(),payloads={};
  try{
   const previous=await store.call('snapshot_get',{leaseId:reference.leaseId});
   const recordingClient={search:async(resource,where,expansions)=>{
    const data=await client.search(resource,where,expansions);payloads[resource]=data;return data;
   }};
   const record=await fetchLeaseFacts(recordingClient,reference,{previous,contractVerified:env.CUBBY_OPERATIONAL_ACCESS_VERIFIED==='true'});
   const exemptions=await recordingClient.search('delinquency-exemptions/search',{leaseId:reference.leaseId});
   const decision=record.kind?evaluateNotification({kind:record.kind,facts:record.facts,recipient:record.recipient,
    assignments:sample.context?.assignments,policy:sample.context?.policy,consent:null}):{eligible:false,reason:'no_transition'};
   const repeated=record.kind?evaluateNotification({kind:record.kind,facts:record.facts,recipient:record.recipient,
    assignments:sample.context?.assignments,policy:sample.context?.policy,consent:null}):decision;
   const lease=payloads['leases/search'].leases.find(l=>l.leaseId===reference.leaseId);
   const compliance=payloads['leases/search'].compliances?.find(c=>c.leaseId===reference.leaseId);
   const ledger=payloads['ledgers/search'].ledgers.find(l=>l.leaseId===reference.leaseId);
   const payments=[...payloads['payments/search'].payments].sort((a,b)=>String(b.createdAt).localeCompare(String(a.createdAt)));
   const active=(sample.context?.assignments||[]).filter(a=>a.releasedAt==null&&a.facilityId===reference.facilityId&&a.unitId===reference.unitId);
   const status=s=>['SUCCEEDED','APPROVING','PENDING','FAILED','DECLINED','REFUNDED','CANCELLED','APPROVED','NEW'].includes(s)?s:s==null?null:'OTHER';
   const exemptRows=exemptions.delinquencyExemptions;
   results.push({state:'observed',kind:record.kind,eligible:decision.eligible,reason:decision.reason,
    durationMs:Date.now()-begin,verifiedAt:record.facts.verifiedAt,sourceUpdatedAt:record.sourceVersion,
    sourceRentalCreatedAt:lease.createdAt||null,sourcePaymentCreatedAt:payments[0]?.createdAt||null,
    sourceEventAt:record.facts.occurredAt,sourceVersionMatchesCheckpoint:record.sourceVersion===previous?.sourceVersion,
    checks:{currentLease:record.facts.active,leasePaid:record.facts.leasePaid,overlockNeeded:record.facts.overlockNeeded,
     ledgerNonpositive:Number.isFinite(ledger.balances?.totalDue)&&ledger.balances.totalDue<=0,
     latestPaymentStatus:status(payments[0]?.status),paymentCount:payments.length,paymentClear:record.facts.paymentClear,
     ledgerEntryCount:Array.isArray(ledger.bookEntries)?ledger.bookEntries.length:null,
     waivedEntryCount:Array.isArray(ledger.bookEntries)?ledger.bookEntries.filter(e=>e.details?.waive===true).length:null,
     discountEntryCount:Array.isArray(ledger.bookEntries)?ledger.bookEntries.filter(e=>e.details?.category==='DISCOUNT').length:null,
     pendingPaymentCount:payments.filter(p=>['PENDING','APPROVING','NEW','APPROVED'].includes(p.status)).length,
     paymentTimestampZoneExplicit:typeof payments[0]?.createdAt==='string'&&/(Z|[+-]\d\d:\d\d)$/.test(payments[0].createdAt),
     documentsSatisfied:record.facts.requirementsSatisfied,documentStatuses:[...new Set([...(compliance?.documents||[]),...(compliance?.otherDocuments||[])].map(d=>['APPROVED','NOT_REQUIRED','PENDING','REJECTED','MISSING_SIGNATURE','INCOMPLETE','COMPLETE'].includes(d.status)?d.status:'OTHER'))],
     moveInAllowed:record.facts.moveInAllowed,auctionClear:record.facts.auctionClear,restrictionsClear:record.facts.restrictionsClear,
     authorizedAccountPhoneAvailable:record.recipient.verified,sourceSuppressed:record.recipient.suppressed,
     verifiedProgramConsent:false,activeAssignmentCount:active.length,
     expectedAssignmentType:record.kind==='overlock_clearance'?'overlock':record.kind==='new_rental'?'vacant':null,
     currentAssignmentTypes:active.map(a=>['vacant','overlock','auction','unclassified','tenant_held'].includes(a.type)?a.type:'OTHER'),
     currentCombinationVersionBound:active.length===1&&Number.isInteger(active[0].lockVersion),
     encryptedCombinationPresent:sample.context?.encryptedCombinationPresent===true,
     originalAssignmentTimeKnown:active.length===1&&Number.isFinite(Date.parse(active[0].assignedAt)),
     importedAssignmentEvidenceAvailable:active.length===1&&active[0].importedMappingVerified===true,
     exemptionCollectionAvailable:Array.isArray(exemptRows),exemptionCount:Array.isArray(exemptRows)?exemptRows.length:null,
     exemptionFields:Array.isArray(exemptRows)?[...new Set(exemptRows.flatMap(e=>Object.keys(e)))].filter(k=>/^[a-zA-Z][a-zA-Z0-9_]{0,60}$/.test(k)).sort():[],
     exemptionPausesOverlock:Array.isArray(exemptRows)&&exemptRows.some(e=>e.pauseOverlock===true),
     repeatedDecisionStable:decision.reason===repeated.reason&&decision.key===repeated.key},templateVersion:TEMPLATE_VERSION});
  }catch(error){results.push({state:'blocked',reason:error instanceof IntegrationError?error.code:'preactivation_observation_failed',durationMs:Date.now()-begin,
   responseCounts:Object.fromEntries(Object.entries(payloads).map(([resource,data])=>[resource,Object.fromEntries(Object.entries(data).filter(([,rows])=>Array.isArray(rows)).map(([key,rows])=>[key,rows.length]))]))})}
 }
 return {state:'observed',verifiedAt:new Date().toISOString(),durationMs:Date.now()-started,mode:'read_only_shadow',results,
  counts:{observed:results.filter(r=>r.state==='observed').length,eligible:results.filter(r=>r.eligible).length,blocked:results.filter(r=>!r.eligible).length},
  consentNote:'This observer does not assume or create consent. Consent readiness must be checked separately against verified production receipts.',
  databaseWrites:0,combinationDecryptions:0,smsSubmitted:0};
}
