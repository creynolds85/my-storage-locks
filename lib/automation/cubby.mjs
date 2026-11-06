import {normalizePhone,digest} from './policy.mjs';
const ROOT='https://api.cubbystorage.com/v1/';
const READS=new Set(['facilities/search','units/search','leases/search','customers/search','payments/search','ledgers/search','auctions/search','delinquency-exemptions/search']);
export class IntegrationError extends Error{constructor(code,retryAfter=60){super(code);this.code=code;this.retryAfter=retryAfter}}
export function createCubbyClient({apiKey,fetcher=fetch,limit=80}={}){
 let calls=0;
 return {async search(resource,where,expansions=[]){
  if(!READS.has(resource))throw new IntegrationError('cubby_operation_not_allowed');
  if(!apiKey)throw new IntegrationError('cubby_credentials_missing',300);
  if(++calls>limit)throw new IntegrationError('cubby_request_budget_exhausted');
  let response;
  try{response=await fetcher(ROOT+resource,{method:'POST',headers:{Authorization:'Bearer '+apiKey,'Content-Type':'application/json'},body:JSON.stringify({where,...(expansions.length?{expansions}: {})}),signal:AbortSignal.timeout(10000),redirect:'error',cache:'no-store'})}catch{throw new IntegrationError('cubby_unreachable')}
  if(response.status===429)throw new IntegrationError('cubby_rate_limited',Math.min(900,Math.max(60,Number(response.headers.get('retry-after'))||60)));
  if(!response.ok)throw new IntegrationError(response.status===401||response.status===403?'cubby_permission_denied':'cubby_request_failed');
  let json;try{json=await response.json()}catch{throw new IntegrationError('cubby_response_invalid')}
  if(json.status!==200||!json.data||json.errors)throw new IntegrationError('cubby_response_rejected');
  // Never treat undocumented truncation/pagination as a complete response.
  if(json.nextCursor||json.data.nextCursor||json.hasMore||json.data.hasMore)throw new IntegrationError('cubby_pagination_unverified');
  return json.data;
 }};
}
export function exact(rows,id,field){const matches=(rows||[]).filter(r=>r[field]===id);if(matches.length!==1)throw new IntegrationError('cubby_identity_ambiguous');return matches[0]}
export function sourceDate(now,timeZone){if(!timeZone)throw new IntegrationError('facility_timezone_missing');return new Intl.DateTimeFormat('en-CA',{timeZone,year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(now))}
export async function fetchLeaseFacts(client,reference,{previous=null,eventType='poll',occurredAt=null,now=Date.now(),contractVerified=false}={}){
 const initial=await client.search('leases/search',{leaseId:reference.leaseId},['unit','customer','compliance']);
 const lease=exact(initial.leases,reference.leaseId,'leaseId');
 if(lease.facilityId!==reference.facilityId||lease.unitId!==reference.unitId||lease.customerId!==reference.customerId)throw new IntegrationError('lease_identity_changed');
 const [units,customers,ledgers,payments,auctions,facilities]=await Promise.all([
  client.search('units/search',{unitId:lease.unitId}),client.search('customers/search',{customerId:lease.customerId}),
  client.search('ledgers/search',{leaseId:lease.leaseId}),client.search('payments/search',{leaseId:lease.leaseId}),
  client.search('auctions/search',{facilityId:lease.facilityId}),client.search('facilities/search',{facilityId:lease.facilityId})
 ]);
 const unit=exact(units.units,lease.unitId,'unitId');const customer=exact(customers.customers,lease.customerId,'customerId');
 const ledger=exact(ledgers.ledgers,lease.leaseId,'leaseId');const facility=exact(facilities.facilities,lease.facilityId,'facilityId');
 if(!Array.isArray(payments.payments)||!Array.isArray(auctions.auctions))throw new IntegrationError('cubby_collections_missing');
 const current=unit.leaseId===lease.leaseId&&unit.facilityId===lease.facilityId&&unit.free===false&&lease.moveOutDate==null;
 const today=sourceDate(now,facility.timeZone);
 const moveInAllowed=typeof lease.moveInDate==='string'&&lease.moveInDate.slice(0,10)<=today;
 const compliance=(initial.compliances||[]).find(c=>c.leaseId===lease.leaseId);
 const docs=compliance?[...(compliance.documents||[]),...(compliance.otherDocuments||[])]:null;
 const requirementsSatisfied=Array.isArray(docs)&&Array.isArray(compliance.documents)&&docs.every(d=>['APPROVED','NOT_REQUIRED'].includes(d.status));
 const paymentRows=[...payments.payments].sort((a,b)=>String(b.createdAt).localeCompare(String(a.createdAt)));
 const latest=paymentRows[0];
 // Conservative draft rule; it must be approved against actual facility rules before live use.
 const paymentClear=Number.isFinite(ledger.balances?.totalDue)&&ledger.balances.totalDue<=0&&latest?.status==='SUCCEEDED';
 const auctionClear=auctions.auctions.every(a=>Array.isArray(a.auctionedLeases)&&a.auctionedLeases.every(l=>l.leaseId!==lease.leaseId||l.status==='CANCELLED'));
 const prefs=customer.communicationPreferences?.sms;
 const old=previous?.facts;
 const clearanceTransition=lease.overlockNeeded===false&&(old?.overlockNeeded===true||old?.clearanceTransition===true);
 const completed=current&&(eventType==='move_in'||old?.active===false||old?.rentalCompleted===true||(!old&&Number.isFinite(Date.parse(lease.createdAt))));
 const transition=eventType==='move_in'||(completed&&!clearanceTransition)?'new_rental':clearanceTransition?'overlock_clearance':null;
 const blockedEpisode=lease.overlockNeeded===true?(old?.overlockNeeded===true?old?.blockedEpisode:digest([lease.leaseId,lease.updatedAt,'blocked'].join(':'))):old?.blockedEpisode||null;
 const episodeId=transition==='new_rental'?digest([lease.leaseId,lease.moveInDate,'rental'].join(':')):transition==='overlock_clearance'?blockedEpisode:null;
 const rentalOccurredAt=old?.rentalCompleted?old.rentalOccurredAt:eventType==='move_in'?occurredAt:old?.active===false?lease.updatedAt:lease.createdAt;
 const clearanceOccurredAt=old?.clearanceTransition?old.clearanceOccurredAt:occurredAt||lease.updatedAt;
 const triggerTime=transition==='new_rental'?rentalOccurredAt:transition==='overlock_clearance'?clearanceOccurredAt:occurredAt||lease.updatedAt;
 const facts={rentalAccessReady:current&&moveInAllowed&&requirementsSatisfied,releaseAccessReady:contractVerified&&current&&moveInAllowed&&paymentClear&&auctionClear&&lease.overlockNeeded===false,rentalOccurredAt,clearanceOccurredAt,verified:contractVerified,verifiedAt:new Date(now).toISOString(),occurredAt:triggerTime||null,facilityId:lease.facilityId,unitId:lease.unitId,leaseId:lease.leaseId,customerId:lease.customerId,active:current&&moveInAllowed,overlockNeeded:typeof lease.overlockNeeded==='boolean'?lease.overlockNeeded:null,paymentClear,requirementsSatisfied,rentalCompleted:completed,moveInAllowed,auctionClear,restrictionsClear:contractVerified&&auctionClear,clearanceTransition,episodeId,blockedEpisode};
 return {facts,kind:transition,sourceVersion:lease.updatedAt||null,unitLabel:unit.name,facilityName:facility.name,recipient:{customerId:lease.customerId,phone:normalizePhone(customer.contact?.phone),verified:!!normalizePhone(customer.contact?.phone),suppressed:typeof prefs?.suppressed==='boolean'?prefs.suppressed:null},raw:{leaseId:lease.leaseId,facilityId:lease.facilityId,unitId:lease.unitId,customerId:lease.customerId}};
}
