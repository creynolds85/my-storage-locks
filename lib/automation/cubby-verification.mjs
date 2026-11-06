import {createCubbyClient,IntegrationError,fetchLeaseFacts} from './cubby.mjs';
const fields=value=>value&&typeof value==='object'?Object.keys(value).filter(k=>/^[a-zA-Z][a-zA-Z0-9_]{0,60}$/.test(k)).sort():[];
/** @param {any} env @param {{store?:any,client?:any}} options */
export async function verifyCubby(env,{store,client=createCubbyClient({apiKey:env.CUBBY_API_KEY,limit:40})}={}){
 const started=Date.now(),checks=[];
 const result={verifiedAt:new Date().toISOString(),operatorTokenConfigured:!!env.CUBBY_API_KEY,bigQueryConfigured:!!env.CUBBY_BIGQUERY_SERVICE_ACCOUNT_JSON,authenticationVerified:false,mode:'read_only',smsSendingEnabled:env.LOCKS_LIVE_SMS_ENABLED==='true',checks};
 if(!env.CUBBY_API_KEY)return {...result,state:'configuration_required',reason:'cubby_credentials_missing'};
 if(env.CUBBY_API_KEY.trim().startsWith('{')||/^Bearer\s/i.test(env.CUBBY_API_KEY))return {...result,state:'configuration_invalid',reason:'operator_token_format_invalid'};
 async function read(resource,where,collection,expansions=[]){
  const before=Date.now();try{
   const data=await client.search(resource,where,expansions),rows=data[collection];
   const timestamps=(Array.isArray(rows)?rows:[]).map(r=>r.updatedAt).filter(x=>typeof x==='string'&&/(Z|[+-]\d\d:\d\d)$/.test(x)&&Number.isFinite(Date.parse(x))).sort();
   checks.push({endpoint:resource,ok:Array.isArray(rows),durationMs:Date.now()-before,count:Array.isArray(rows)?rows.length:null,collectionComplete:Array.isArray(rows)&&rows.length<1000,responseFields:fields(data),recordFields:fields(rows?.[0]),newestSourceUpdatedAt:timestamps.at(-1)||null});return data;
  }catch(error){checks.push({endpoint:resource,ok:false,durationMs:Date.now()-before,errorCode:error instanceof IntegrationError?error.code:'verification_failed'});return null}
 }
 const fac=await read('facilities/search',{organizationId:env.CUBBY_ORGANIZATION_ID},'facilities');if(!fac)return {...result,state:'authentication_or_connection_failed',durationMs:Date.now()-started};
 result.authenticationVerified=true;
 const links=await store.call('links'),allowed=new Set(links.filter(l=>l.orgId===env.CUBBY_ORGANIZATION_ID).map(l=>l.sourceFacilityId));
 const facilities=(fac.facilities||[]).filter(f=>allowed.has(f.facilityId));
 result.facilityScope={mapped:allowed.size,accessible:facilities.length,allMappedAccessible:allowed.size>0&&facilities.length===allowed.size,unexpectedFacilityCount:(fac.facilities||[]).filter(f=>!allowed.has(f.facilityId)).length};
 const facility=facilities[0];if(!facility)return {...result,state:'facility_scope_unverified'};
 const [units,leases,customers]=await Promise.all([
  read('units/search',{facilityId:facility.facilityId},'units'),
  read('leases/search',{facilityId:facility.facilityId},'leases'),
  read('customers/search',{facilityId:facility.facilityId},'customers')
 ]);
 const sample=(leases?.leases||[]).find(l=>l.facilityId===facility.facilityId&&l.unitId&&l.customerId&&l.moveOutDate==null);
 const leaseId=sample?.leaseId||(units?.units||[]).find(u=>u.leaseId&&u.free===false)?.leaseId;
 const detail=leaseId?await read('leases/search',{leaseId},'leases',['unit','customer','compliance']):null;
 const lease=(detail?.leases||[]).find(l=>l.leaseId===leaseId&&l.facilityId===facility.facilityId);
 if(lease){
  const [payments,ledgers,auctions,exemptions]=await Promise.all([
   read('payments/search',{leaseId:lease.leaseId},'payments'),read('ledgers/search',{leaseId:lease.leaseId},'ledgers'),
   read('auctions/search',{facilityId:facility.facilityId},'auctions'),read('delinquency-exemptions/search',{leaseId:lease.leaseId},'delinquencyExemptions')
  ]);
  const customer=(customers?.customers||[]).find(c=>c.customerId===lease.customerId),ledger=(ledgers?.ledgers||[]).find(l=>l.leaseId===lease.leaseId);
  result.authorizationFields={lease:fields(lease),unit:fields((units?.units||[]).find(u=>u.unitId===lease.unitId)),customerContact:fields(customer?.contact),customerCommunicationPreferences:fields(customer?.communicationPreferences),smsPreferences:fields(customer?.communicationPreferences?.sms),customerPhoneAvailable:typeof customer?.contact?.phone==='string'&&customer.contact.phone.length>0,complianceCollectionAvailable:Array.isArray(detail?.compliances),compliance:fields(detail?.compliances?.[0]),balanceFields:fields(ledger?.balances),paymentStatuses:[...new Set((payments?.payments||[]).map(p=>p.status).filter(s=>['SUCCEEDED','APPROVED','FAILED','DECLINED','NEW','APPROVING','PENDING','REFUNDED','CANCELLED'].includes(s)))],auctionCollectionAvailable:Array.isArray(auctions?.auctions),exemptionResponseFields:fields(exemptions),facilityTimeZoneAvailable:typeof facility.timeZone==='string'};
  try{
   const payloads={'leases/search':detail,'units/search':units,'customers/search':customers,'ledgers/search':ledgers,'payments/search':payments,'auctions/search':auctions,'facilities/search':fac};
   const normalized=await fetchLeaseFacts({search:async(resource)=>payloads[resource]},{leaseId:lease.leaseId,unitId:lease.unitId,customerId:lease.customerId,facilityId:lease.facilityId},{contractVerified:true});
   result.adapterContract={valid:true,phoneNormalized:!!normalized.recipient.phone,sourceVerified:normalized.facts.verified,leasePaidType:typeof normalized.facts.leasePaid,overlockNeededType:typeof normalized.facts.overlockNeeded,restrictionDecisionType:typeof normalized.facts.restrictionsClear,complianceDecisionType:typeof normalized.facts.requirementsSatisfied,paymentDecisionType:typeof normalized.facts.paymentClear};
  }catch(error){result.adapterContract={valid:false,errorCode:error instanceof IntegrationError?error.code:'adapter_contract_failed'}}
  const after=new Date(Date.now()-600000).toISOString(),before=new Date().toISOString();
  const incremental=await read('leases/search',{facilityId:facility.facilityId,updatedAfter:after,updatedBefore:before},'leases');
  result.incrementalFilter={windowSeconds:600,returned:incremental?.leases?.length??null,outsideWindowCount:incremental?.leases?.filter(l=>!Number.isFinite(Date.parse(l.updatedAt))||Date.parse(l.updatedAt)<=Date.parse(after)||Date.parse(l.updatedAt)>=Date.parse(before)).length??null};
 }
 return {...result,state:checks.every(c=>c.ok)?'connected':'partial_access',durationMs:Date.now()-started,eventVisibilityLatencyMeasured:false,productionInventoryWrites:0};
}
/** Execute the existing poller with in-memory checkpoints and inbox only. */
export async function probeCubbyPolling(env,store){
 const {pollOperationalData}=await import('./worker.mjs');
 const started=Date.now(),links=await store.call('links'),after=new Date(started-120000).toISOString();
 const cursors=Object.fromEntries(links.map(l=>[l.sourceFacilityId,{baseline:true,leaseAfter:after,customerAfter:after}]));
 const rows={},timings=[],events=new Set(),samples=[];let unitCount=0,duplicates=0,facilitiesRead=0,finish=null;
 const client=createCubbyClient({apiKey:env.CUBBY_API_KEY,limit:100});
 const shadow={call:async(op,p={})=>{
  if(op==='sync_claim')return {cursors};if(op==='links')return links;
  if(op==='units_save'){unitCount+=p.units.length;facilitiesRead++;return {ok:true}}
  if(op==='references_for_customer')return [];
  if(op==='inbox_accept'){if(events.has(p.key)){duplicates++;return null}events.add(p.key);const timestamp=Date.parse(p.occurredAt);if(samples.length<12&&Number.isFinite(timestamp))samples.push({sourceUpdatedAt:p.occurredAt,firstObservedAt:new Date().toISOString(),sourceAgeSeconds:Math.round((Date.now()-timestamp)/1000),changedDuringProbe:timestamp>=started});return {id:'shadow-event'}}
  if(op==='sync_finish'){finish={ok:p.ok,errorCode:p.errorCode||null};return {ok:true}}
  throw Error('unsupported_shadow_operation');
 }};
 const result=await pollOperationalData({env,store:shadow,client:{search:async(resource,where,expansions)=>{const start=Date.now();const data=await client.search(resource,where,expansions);timings.push(Date.now()-start);for(const [key,value] of Object.entries(data)){if(Array.isArray(value))rows[key]=Math.max(rows[key]||0,value.length)}return data}}});
 return {state:result.state,reason:result.reason||null,shadowMode:true,startedAt:new Date(started).toISOString(),finishedAt:new Date().toISOString(),durationMs:Date.now()-started,mappedFacilities:links.length,facilitiesRead,unitsRead:unitCount,apiCalls:timings.length,maxCollectionSizes:rows,requestDurationMs:{min:Math.min(...timings),max:Math.max(...timings),mean:timings.length?Math.round(timings.reduce((a,b)=>a+b,0)/timings.length):null},newEvents:events.size,duplicates,sourceSamples:samples,finish,databaseWrites:0,smsSubmitted:0,physicalAssignmentWrites:0,eventTransitionLatencyVerified:false};
}
