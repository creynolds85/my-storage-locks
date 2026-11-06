import {createCubbyClient,IntegrationError} from './cubby.mjs';
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
  read('leases/search',{facilityId:facility.facilityId},'leases',['unit','customer','compliance']),
  read('customers/search',{facilityId:facility.facilityId},'customers')
 ]);
 const lease=(leases?.leases||[]).find(l=>l.facilityId===facility.facilityId&&l.unitId&&l.customerId&&l.moveOutDate==null);
 if(lease){
  const [payments,ledgers,auctions,exemptions]=await Promise.all([
   read('payments/search',{leaseId:lease.leaseId},'payments'),read('ledgers/search',{leaseId:lease.leaseId},'ledgers'),
   read('auctions/search',{facilityId:facility.facilityId},'auctions'),read('delinquency-exemptions/search',{leaseId:lease.leaseId},'delinquencyExemptions')
  ]);
  const customer=(customers?.customers||[]).find(c=>c.customerId===lease.customerId),ledger=(ledgers?.ledgers||[]).find(l=>l.leaseId===lease.leaseId);
  result.authorizationFields={lease:fields(lease),unit:fields((units?.units||[]).find(u=>u.unitId===lease.unitId)),customerContact:fields(customer?.contact),customerCommunicationPreferences:fields(customer?.communicationPreferences),smsPreferences:fields(customer?.communicationPreferences?.sms),customerPhoneAvailable:typeof customer?.contact?.phone==='string'&&customer.contact.phone.length>0,complianceCollectionAvailable:Array.isArray(leases?.compliances),compliance:fields(leases?.compliances?.[0]),balanceFields:fields(ledger?.balances),paymentStatuses:[...new Set((payments?.payments||[]).map(p=>p.status).filter(s=>['SUCCEEDED','APPROVED','FAILED','DECLINED','NEW','APPROVING','PENDING','REFUNDED','CANCELLED'].includes(s)))],auctionCollectionAvailable:Array.isArray(auctions?.auctions),exemptionResponseFields:fields(exemptions),facilityTimeZoneAvailable:typeof facility.timeZone==='string'};
  const after=new Date(Date.now()-600000).toISOString(),before=new Date().toISOString();
  const incremental=await read('leases/search',{facilityId:facility.facilityId,updatedAfter:after,updatedBefore:before},'leases');
  result.incrementalFilter={windowSeconds:600,returned:incremental?.leases?.length??null,outsideWindowCount:incremental?.leases?.filter(l=>!Number.isFinite(Date.parse(l.updatedAt))||Date.parse(l.updatedAt)<=Date.parse(after)||Date.parse(l.updatedAt)>=Date.parse(before)).length??null};
 }
 return {...result,state:checks.every(c=>c.ok)?'connected':'partial_access',durationMs:Date.now()-started,eventVisibilityLatencyMeasured:false,productionInventoryWrites:0};
}
