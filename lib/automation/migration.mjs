// One-time, read-only reconciliation. This module deliberately has no apply/write transport.
export function migrationDryRun(source,existing=[]){
 const rows=Array.isArray(source)?source:source.locks;if(!Array.isArray(rows))throw Error('lock_snapshot_missing');
 const ids=new Set(),serials=new Set(),units=new Map();const counts={};const issues=[];let newRecords=0,exactMatches=0;
 for(const row of rows){
  const id=row.door_lock_id||row.lockId;const serial=row.serial_code??row.serial;const combination=row.combination??row.combo;
  const facility=row.facility_id??row.facilityId;const unit=row.unit_id??row.attachedTo;const status=row.status;
  const key=facility+':'+String(serial).toLowerCase();counts[status]=(counts[status]||0)+1;
  const issue=code=>issues.push({sourceId:id||null,code});
  if(!id||ids.has(id))issue('missing_or_duplicate_source_id');ids.add(id);
  if(typeof serial!=='string'||!/^[a-z0-9]{1,100}$/i.test(serial))issue('serial_must_be_preserved_as_string');
  if(typeof combination!=='string'||!combination||combination.length>200)issue('combination_must_be_preserved_as_string');
  if(!facility)issue('facility_mapping_required');if(serials.has(key))issue('duplicate_facility_serial');serials.add(key);
  if(unit)units.set(facility+':'+unit,(units.get(facility+':'+unit)||0)+1);
  if(['ACTIVE','OPERATOR_USE','IN_TENANT','TENANT_USE'].includes(status))issue('preserve_assignment_classification_required');
  const matches=existing.filter(e=>e.sourceId===id||e.facilityId===facility&&e.serial.toLowerCase()===String(serial).toLowerCase());
  if(matches.length===0)newRecords++;
  else if(matches.length===1&&matches[0].sourceId===id&&matches[0].combination===combination&&matches[0].unitId===unit&&matches[0].sourceStatus===status)exactMatches++;
  else issue('existing_record_conflict_no_overwrite');
 }
 return {mode:'dry_run_only',total:rows.length,facilities:new Set(rows.map(r=>r.facility_id??r.facilityId)).size,statusCounts:counts,newRecords,exactMatches,unitsWithMultipleLocks:[...units.values()].filter(n=>n>1).length,issues,productionRecordsApplied:0};
}
