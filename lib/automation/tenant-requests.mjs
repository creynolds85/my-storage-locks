import {BigQuery} from '@google-cloud/bigquery';
import {warehouseConfig} from './warehouse.mjs';
import {fetchLeaseFacts,IntegrationError,exact} from './cubby.mjs';
import {evaluateTenantRequest,digest,normalizePhone} from './policy.mjs';
const unitKey=value=>String(value||'').trim().toLowerCase();
const sourceReady=env=>!!env.CUBBY_API_KEY&&!!env.CUBBY_ORGANIZATION_ID&&env.CUBBY_OPERATIONAL_ACCESS_VERIFIED==='true'&&env.CUBBY_RATE_LIMIT_VERIFIED==='true';
export async function refreshTenantDirectory(rt){
 if(!rt.env.CUBBY_BIGQUERY_SERVICE_ACCOUNT_JSON)return;
 if(!(await rt.store.call('tenant_directory_needed')))return;
 try{
  const cfg=warehouseConfig(rt.env),client=new BigQuery({projectId:cfg.project,credentials:cfg.credentials,autoRetry:false,maxRetries:0});
  const [rows]=await client.query({query:`SELECT facility_id,facility_phone FROM \`${cfg.project}.${cfg.dataset}.facilities\` WHERE org_id=@org`,params:{org:cfg.organization},useLegacySql:false,maximumBytesBilled:'104857600',timeoutMs:15000,jobTimeoutMs:15000,useQueryCache:false,location:cfg.location,labels:{app:'my_storage_locks',purpose:'public_facility_contact'}});
  if(rows.length>200)throw Error('directory_scope_invalid');
  await rt.store.call('tenant_directory_save',{orgId:cfg.organization,contacts:rows.map(r=>({sourceFacilityId:r.facility_id,phone:normalizePhone(r.facility_phone)}))});
 }catch{ /* Existing monitoring retains source readiness; no tenant data or credentials are logged. */ }
}
export async function processTenantRequest(rt,id,{revalidate=false}={}){
 const request=await rt.store.call('tenant_get',{id});if(!request)return {state:'blocked'};
 const finish=async reason=>{await rt.store.call('tenant_finish',{id,reason});return {state:'blocked',reason}};
 if(Date.parse(request.expiresAt)<=Date.now())return finish('request_expired');
 if(!sourceReady(rt.env))return finish('operational_source_unverified');
 if(request.sourceOrgId!==rt.env.CUBBY_ORGANIZATION_ID)return finish('facility_mapping_unverified');
 if(!(await rt.store.call('tenant_source_claim',{id,revalidate})))throw new IntegrationError('tenant_verification_rate_limited');
 // Search by facility and unit, never by a caller-supplied phone number.
 const found=await rt.client.search('units/search',{facilityId:request.sourceFacilityId,name:request.unit});
 if(!Array.isArray(found.units)||found.units.length>=1000)throw new IntegrationError('cubby_completeness_unverified');
 const matching=found.units.filter(u=>u.facilityId===request.sourceFacilityId&&unitKey(u.name)===unitKey(request.unit));
 if(matching.length!==1||!matching[0].leaseId||matching[0].free!==false)return finish('rental_unverified');
 const unit=matching[0],leases=await rt.client.search('leases/search',{leaseId:unit.leaseId},['unit','customer']);
 const lease=exact(leases.leases,unit.leaseId,'leaseId');
 if(lease.facilityId!==request.sourceFacilityId||lease.unitId!==unit.unitId||!lease.customerId)return finish('rental_unverified');
 const reference={leaseId:lease.leaseId,facilityId:lease.facilityId,unitId:unit.unitId,customerId:lease.customerId};
 const previous=await rt.store.call('snapshot_get',{leaseId:lease.leaseId});
 const record=await fetchLeaseFacts(rt.client,reference,{previous,eventType:'tenant_request',contractVerified:true});
 if(unitKey(record.unitLabel)!==unitKey(request.unit)||digest(normalizePhone(record.recipient.phone)||'')!==request.phoneDigest)return finish('recipient_unverified');
 await rt.store.call('units_save',{orgId:request.sourceOrgId,units:[{unitId:unit.unitId,facilityId:unit.facilityId,name:unit.name,operationalState:{leaseId:unit.leaseId,free:unit.free}}]});
 await rt.store.call('snapshot_save',{...record,orgId:request.sourceOrgId});
 const context=await rt.store.call('context',{leaseId:lease.leaseId});
 const current=context?.assignments?.filter(a=>a.releasedAt==null&&a.facilityId===reference.facilityId&&a.unitId===reference.unitId)||[];
 const kind=current.length===1&&current[0].type==='overlock'?'overlock_clearance':'new_rental';
 const decision=evaluateTenantRequest({request,contextFacilityId:context?.facilityId,kind,facts:record.facts,assignments:context?.assignments,recipient:record.recipient,consent:context?.consent,policy:context?.policy});
 if(!decision.eligible){
  if(['missing_assignment','conflicting_assignment','auction_assignment','assignment_changed','consent_unverified','sms_suppressed'].includes(decision.reason))await rt.store.call('exception',{orgId:request.sourceOrgId,facilityId:request.sourceFacilityId,key:digest(['tenant-access',request.facilityId,request.unitHash,decision.reason].join(':')),reason:decision.reason});
  return finish(decision.reason);
 }
 const verified=await rt.store.call('tenant_verify',{id,leaseId:lease.leaseId,...decision});
 if(!verified?.verified){if(verified?.reason==='assignment_changed')await rt.store.call('exception',{orgId:request.sourceOrgId,facilityId:request.sourceFacilityId,key:digest(['tenant-access',request.facilityId,request.unitHash,'assignment_changed'].join(':')),reason:'assignment_changed'});return finish(verified?.reason||'eligibility_unverified');}
 if(revalidate)return {state:'verified'};
 return await rt.store.call('tenant_enqueue',{id,consentId:context.consent.proofId,...decision})||await finish('eligibility_or_assignment_changed');
}
