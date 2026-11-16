import {IntegrationError} from './cubby.mjs';
// Investigation only: no combination is retained or returned, and no inventory write occurs.
export async function inspectLockAssignments(rt,facilityId){
 if(!/^[a-f0-9-]{36}$/.test(facilityId||''))throw new IntegrationError('facility_required');
 const links=await rt.store.call('links');const link=links.find(l=>l.facilityId===facilityId&&l.orgId===rt.env.CUBBY_ORGANIZATION_ID);
 if(!link)throw new IntegrationError('facility_mapping_unverified');
 const [catalog,unitData]=await Promise.all([rt.client.search('locks/search',{organizationId:link.orgId}),rt.client.search('units/search',{facilityId:link.sourceFacilityId})]);
 if(!Array.isArray(catalog.locks)||catalog.locks.length>10000||!Array.isArray(unitData.units)||unitData.units.length>=1000)throw new IntegrationError('lock_catalog_incomplete');
 if(unitData.units.some(u=>u.facilityId!==link.sourceFacilityId||!u.unitId||!u.name)||new Set(unitData.units.map(u=>u.unitId)).size!==unitData.units.length||new Set(unitData.units.map(u=>u.name.trim().toLowerCase())).size!==unitData.units.length)throw new IntegrationError('unit_identity_ambiguous');
 const units=new Map(unitData.units.map(u=>[u.unitId,u]));const ids=new Set();const records=[];
 for(const source of catalog.locks){
  const id=source.lockId||source.id;if(!id||ids.has(id)||(source.lockId&&source.id&&source.lockId!==source.id))throw new IntegrationError('lock_identity_ambiguous');ids.add(id);
  if(source.facilityId!==link.sourceFacilityId)continue;
  if(source.organizationId&&source.organizationId!==link.orgId)throw new IntegrationError('lock_organization_mismatch');
  if(!['AVAILABLE','OPERATOR_USE','TENANT_USE','DISABLED'].includes(source.status)||!source.serial)throw new IntegrationError('lock_status_unverified');
  const unit=source.attachedTo?units.get(source.attachedTo):null;
  if(['OPERATOR_USE','TENANT_USE'].includes(source.status)&&!unit)throw new IntegrationError('lock_unit_unverified');
  records.push({sourceLockId:id,serial:source.serial,sourceFacilityId:source.facilityId,sourceUnitId:unit?.unitId||null,unit:unit?.name||null,status:source.status,disabledReason:source.disabledReason||null,unitVacant:unit?.free===true,unitOverlocked:unit?.overlocked===true,sourceUpdatedAt:typeof source.updatedAt==='string'?source.updatedAt:null});
 }
 return {state:'connected',mode:'read_only',observedAt:new Date().toISOString(),sourceFacilityId:link.sourceFacilityId,organizationLockCount:catalog.locks.length,facilityLockCount:records.length,inventoryWrites:0,combinationsReturned:false,records};
}
