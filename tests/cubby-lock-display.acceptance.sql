begin;

insert into public.facilities(id,name,identifier,source_org_id,source_facility_id)
 values('98500000-0000-0000-0000-000000000001','Combo Labels Fixture','COMBO-LABEL-QA','org_ComboLabelQA','fac_ComboLabelQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id)
 values('org_ComboLabelQA','fac_ComboLabelQA','98500000-0000-0000-0000-000000000001');

do $$
<<cubby_test>>
declare
 row_json jsonb:='{"sourceLockId":"lock_ComboLabelQA","serial":"COMBOLABELQA","facilityId":"fac_ComboLabelQA","unitId":"unit_ComboLabelQA","unit":"042","unitMatches":1,"status":"ACTIVE","updatedAt":"2026-11-18 09:00:00","combination":null,"combinationAvailable":false}';
 step int;
 run uuid;
 lock_id uuid;
 original_assignment uuid;
 actual_assignment uuid;
 expected text;
 labels text[]:=array['Locked','On vacant unit','Overlocked','Locked for auction','Locked','On vacant unit'];
 targets text[]:=array['unclassified','vacant','overlock','auction','auction','auction'];
 snapshot_base timestamptz:=clock_timestamp();
begin
 if has_function_privilege('authenticated','automation.reconcile_cubby_lock_display(text,timestamptz,jsonb)','EXECUTE')
  or has_function_privilege('anon','automation.reconcile_cubby_lock_display(text,timestamptz,jsonb)','EXECUTE') then
  raise exception 'Export reconciliation must be restricted';
 end if;
 for step in 1..6 loop
  insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
  values('org_ComboLabelQA',snapshot_base+step*interval '1 second','combo-label-fixture-'||step,1,
   '{"explicitPurpose":true,"lockDisplayStatusColumn":"display_status"}') returning id into run;
  perform automation.lock_mirror_batch(run,jsonb_build_array(row_json
   || jsonb_build_object('sourceDisplayStatus',labels[step],'updatedAt',case when step=6 then '2026-11-17 09:00:00' else '2026-11-18 09:00:00' end)));
  select l.id,l.status,a.id into strict lock_id,expected,actual_assignment
   from public.locks l join public.assignments a on a.lock_id=l.id and a.released_at is null
   where l.source_org_id='org_ComboLabelQA' and l.source_lock_id='lock_ComboLabelQA';
  if expected<>targets[step] then raise exception 'Wrong Combo Locks classification for step %: %',step,expected;end if;
  if step=1 then
   original_assignment:=actual_assignment;
   insert into private.lock_secrets(lock_id,encrypted) values(cubby_test.lock_id,decode('7634ab0c','hex'));
  elsif actual_assignment<>original_assignment
    or not exists(select 1 from private.lock_secrets s where s.lock_id=cubby_test.lock_id and s.encrypted=decode('7634ab0c','hex')) then
   raise exception 'Classification changed an assignment identity or encrypted combination';
  end if;
 end loop;
 if not exists(select 1 from automation.lock_mirror_records r where r.lock_id=cubby_test.lock_id and r.issue='older_source_record' and not r.purpose_verified) then
  raise exception 'Generic or stale input was incorrectly verified';
 end if;
 update public.locks set source_status='ACTIVE',source_display_status='Locked for auction',
  source_unit_id='unit_ComboLabelQA',source_updated_at='2026-11-18T09:00:00Z' where id=cubby_test.lock_id;
 update automation.lock_mirror_display_evidence set display_status='On vacant unit',
  source='combo_locks_export',observed_at=snapshot_base+interval '7 seconds' where source_org_id='org_ComboLabelQA';
 insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
  values('org_ComboLabelQA',snapshot_base+interval '8 seconds','combo-export-replay',1,'{}') returning id into run;
 perform automation.lock_mirror_batch(run,jsonb_build_array(row_json));
 if not exists(select 1 from public.locks l join public.assignments a on a.lock_id=l.id and a.released_at is null
  where l.id=cubby_test.lock_id and l.status='vacant' and a.id=original_assignment and a.type='vacant') then
  raise exception 'Original import displaced exact current Combo Locks evidence';
 end if;
 for step in 1..5 loop
  insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
  values('org_ComboLabelQA',snapshot_base+(10+step)*interval '1 second','combo-transition-fixture-'||step,1,
   '{"explicitPurpose":true,"lockDisplayStatusColumn":"display_status"}') returning id into run;
  perform automation.lock_mirror_batch(run,jsonb_build_array(row_json||jsonb_build_object(
   'unitId',case when step<=2 then 'unit_ComboTransferQA' end,
   'unit',case when step<=2 then '004' end,
   'unitMatches',case when step<=2 then 1 else 0 end,
   'status',(array['ACTIVE','IN_TENANT','AVAILABLE','MISSING','DAMAGED'])[step],
   'sourceDisplayStatus',(array['On vacant unit','Used by tenant','Available','Missing','Damaged'])[step],
   'updatedAt','2026-11-19 09:00:0'||step)));
  if not exists(select 1 from public.locks l join private.lock_secrets s on s.lock_id=l.id
   where l.id=cubby_test.lock_id and l.status=(array['vacant','tenant_held','available','missing','damaged'])[step]
    and l.unit is not distinct from case when step<=2 then '004' end and s.encrypted=decode('7634ab0c','hex')) then
   raise exception 'Wrong source transition for step %',step;
  end if;
 end loop;
end $$;

rollback;
select 'PASS: exact Combo Locks labels, generic label, stale markers, assignment identity, encryption and permissions' as result;

begin;
insert into public.facilities(id,name,identifier,source_org_id,source_facility_id)
 values('98500000-0000-0000-0000-000000000003','Maintenance Flag Fixture','MAINTENANCE-FLAG-QA','org_MaintQA','fac_MaintQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id)
 values('org_MaintQA','fac_MaintQA','98500000-0000-0000-0000-000000000003');

do $$
declare
 row_json jsonb:='{"sourceLockId":"lock_MaintQA","serial":"MAINTQA","facilityId":"fac_MaintQA","unitId":null,"unit":null,"unitMatches":0,"status":"AVAILABLE","updatedAt":"2026-11-18 09:00:00","combination":null,"combinationAvailable":false}';
 step int;
 run uuid;
 flag jsonb;
 snapshot_base timestamptz:=clock_timestamp();
begin
 for step in 1..3 loop
  flag:=case step when 1 then 'null'::jsonb when 2 then 'true'::jsonb else 'false'::jsonb end;
  insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
   values('org_MaintQA',snapshot_base+step*interval '1 second','maint-fixture-'||step,1,
    case when step=1 then '{}'::jsonb else '{"maintenanceColumn":"is_needs_maintenance"}'::jsonb end)
   returning id into run;
  perform automation.lock_mirror_batch(run,jsonb_build_array(row_json||jsonb_build_object('needsMaintenance',flag)));
 end loop;
 if not exists(select 1 from automation.lock_mirror_records r join public.locks l on l.id=r.lock_id
  where r.source_org_id='org_MaintQA' and l.status='maintenance' and r.needs_maintenance
   and r.issue='source_version_conflict') then
  raise exception 'Maintenance backfill or same-version guard failed';
 end if;
end $$;
rollback;
select 'PASS: one-time numeric maintenance flag backfill and conflicting same-version flag' as result;
