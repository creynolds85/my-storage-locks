begin;
insert into public.facilities(id,name,identifier,source_org_id,source_facility_id) values('97000000-0000-0000-0000-000000000001','Mirror Fixture','MIRROR-QA','org_MirrorQA','fac_MirrorQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id) values('org_MirrorQA','fac_MirrorQA','97000000-0000-0000-0000-000000000001');
insert into automation.unit_links(source_org_id,source_facility_id,source_unit_id,facility_id,label) values('org_MirrorQA','fac_MirrorQA','unit_QA1','97000000-0000-0000-0000-000000000001','0001'),('org_MirrorQA','fac_MirrorQA','unit_QA2','97000000-0000-0000-0000-000000000001','0002');
insert into public.locks(id,serial,color,facility_id,status,unit,source_org_id,source_lock_id,source_unit_id,source_status,source_display_status,source_updated_at,imported_at) values('97000000-0000-0000-0000-000000000002','MIRRORA','Unknown','97000000-0000-0000-0000-000000000001','vacant','0001','org_MirrorQA','lock_QAA','unit_QA1','ACTIVE','On vacant unit','2026-11-01T00:00:00Z','2026-11-05T00:00:00Z');
insert into private.lock_secrets values('97000000-0000-0000-0000-000000000002',extensions.pgp_sym_encrypt('0007',(select value from private.encryption_key)));
insert into public.assignments(id,lock_id,facility_id,unit,type,assigned_at,imported_at,source_display_status) values('97000000-0000-0000-0000-000000000003','97000000-0000-0000-0000-000000000002','97000000-0000-0000-0000-000000000001','0001','vacant',null,now(),'On vacant unit');
insert into auth.users(id,email) values('97000000-0000-0000-0000-000000000004','mirror-fixture@example.invalid');
insert into public.profiles(id,email,name,role) values('97000000-0000-0000-0000-000000000004','mirror-fixture@example.invalid','Mirror Fixture','admin');
insert into automation.operational_snapshots(lease_id,source_org_id,source_facility_id,source_unit_id,customer_id,facts) values('lease_MirrorQA','org_MirrorQA','fac_MirrorQA','unit_QA1','customer_fixture','{}');
insert into automation.sms_consents(id,facility_id,customer_id,phone_hash,purpose,proof_source,proof_version,granted_at,recorded_by) values('97000000-0000-0000-0000-000000000005','97000000-0000-0000-0000-000000000001','customer_fixture','fixture_hash','lock_access','fixture','fixture',now(),'97000000-0000-0000-0000-000000000004');
insert into automation.notification_outbox(id,dedupe_key,kind,facility_id,lease_id,customer_id,source_unit_id,assignment_id,lock_id,lock_version,phone_hash,consent_id,episode_id,template_version,source_occurred_at,state) values('97000000-0000-0000-0000-000000000006','mirror_qa','new_rental','97000000-0000-0000-0000-000000000001','lease_MirrorQA','customer_fixture','unit_QA1','97000000-0000-0000-0000-000000000003','97000000-0000-0000-0000-000000000002',1,'fixture_hash','97000000-0000-0000-0000-000000000005','fixture','fixture',now(),'dry_run');
insert into public.action_items(facility_id,kind,cause_key,title) values('97000000-0000-0000-0000-000000000001','walkthrough_issue','mirror_qa_damage','Door/Latch Damage');
update automation.lock_mirror_control set enabled=true,mode='mirror' where id;
do $$declare owner_id uuid:='97000000-0000-0000-0000-000000000099';run_id uuid;r jsonb;records jsonb;j jsonb;step int;report jsonb;v int;begin
 for step in 1..6 loop
  records:=jsonb_build_array(
   jsonb_build_object('sourceLockId','lock_QAA','serial','MIRRORA','facilityId','fac_MirrorQA','unitId',case when step=1 then 'unit_QA1' else 'unit_QA2' end,'unit',case when step=1 then '0001' else '0002' end,'unitMatches',1,'status','ACTIVE','updatedAt',case when step in(1,3) then '2026-11-01 00:00:00' when step in(2,4) then '2026-11-02 00:00:00' else '2026-11-03 00:00:00' end,'combination',case when step=1 then '0007' when step=4 then 'REJECTED' when step>=5 then 'BLOCKED' else '00-A 01' end,'needsMaintenance',false),
   jsonb_build_object('sourceLockId','lock_QAB','serial','000MIRRORB','facilityId','fac_MirrorQA','unitId',null,'unit',null,'unitMatches',0,'status','AVAILABLE','updatedAt','2026-11-01 00:00:00','combination','0000','needsMaintenance',false)
  );
  if step<>6 then records:=records||jsonb_build_array(jsonb_build_object('sourceLockId','lock_QAC','serial','MIRRORC','facilityId','fac_MirrorQA','unitId','unit_QA1','unit','0001','unitMatches',1,'status','ACTIVE','updatedAt','2026-11-01 00:00:00','combination','12-XY','needsMaintenance',false));end if;
  if step=4 then update public.locks set notes='Local concurrent fixture edit',version=version+1 where source_lock_id='lock_QAB' and source_org_id='org_MirrorQA';end if;
  if step=5 then update automation.notification_outbox set state='unknown' where id='97000000-0000-0000-0000-000000000006';end if;
  r:=automation.lock_mirror_worker('lock_mirror_claim',jsonb_build_object('owner',owner_id,'force',true));if r is null then raise exception 'FAIL claim';end if;
  r:=automation.lock_mirror_worker('lock_mirror_start',jsonb_build_object('owner',owner_id,'orgId','org_MirrorQA','snapshotAt',now()-interval '1 minute'+step*interval '1 second','key','qa'||step,'total',jsonb_array_length(records),'capabilities','{}'::jsonb));
  if r->>'id' is null then raise exception 'FAIL start: %',r;end if;run_id:=(r->>'id')::uuid;
  r:=automation.lock_mirror_worker('lock_mirror_batch',jsonb_build_object('owner',owner_id,'runId',run_id,'records',records));if r->>'saved' is distinct from 'true' then raise exception 'FAIL batch: %',r;end if;
  r:=automation.lock_mirror_worker('lock_mirror_finish',jsonb_build_object('owner',owner_id,'runId',run_id));if r->>'mode' is distinct from 'mirror' then raise exception 'FAIL finish: %',r;end if;
  if step=1 then
   if (select count(*) from public.locks where source_org_id='org_MirrorQA')<>3 then raise exception 'FAIL new inventory';end if;
   if not (select purpose_verified from automation.lock_mirror_records where source_org_id='org_MirrorQA' and source_lock_id='lock_QAA') then raise exception 'FAIL imported verified purpose';end if;
   if (select status from public.locks where source_org_id='org_MirrorQA' and source_lock_id='lock_QAC')<>'unclassified' then raise exception 'FAIL inferred purpose';end if;
  elsif step=2 then
   if (select unit from public.locks where id='97000000-0000-0000-0000-000000000002')<>'0002' then raise exception 'FAIL assignment transition';end if;
   if (select extensions.pgp_sym_decrypt(encrypted,(select value from private.encryption_key)) from private.lock_secrets where lock_id='97000000-0000-0000-0000-000000000002')<>'00-A 01' then raise exception 'FAIL exact encrypted combination';end if;
   if (select state from automation.notification_outbox where id='97000000-0000-0000-0000-000000000006')<>'cancelled' then raise exception 'FAIL stale queued notification';end if;
   if (select released_at from public.assignments where id='97000000-0000-0000-0000-000000000003') is null then raise exception 'FAIL assignment history';end if;
  elsif step=3 then
   if (select unit from public.locks where id='97000000-0000-0000-0000-000000000002')<>'0002' or (select issue from automation.lock_mirror_records where source_org_id='org_MirrorQA' and source_lock_id='lock_QAA')<>'older_source_record' then raise exception 'FAIL stale source protection';end if;
  elsif step=4 then
   if (select issue from automation.lock_mirror_records where source_org_id='org_MirrorQA' and source_lock_id='lock_QAA')<>'source_version_conflict' then raise exception 'FAIL conflicting source version';end if;
   if (select notes from public.locks where source_org_id='org_MirrorQA' and source_lock_id='lock_QAB')<>'Local concurrent fixture edit' then raise exception 'FAIL local conflict preserved';end if;
  elsif step=5 then
   if (select issue from automation.lock_mirror_records where source_org_id='org_MirrorQA' and source_lock_id='lock_QAA')<>'notification_outcome_unresolved' then raise exception 'FAIL uncertain SMS outcome protection';end if;
  elsif step=6 then
   if (select count(*) from public.locks where source_org_id='org_MirrorQA')<>3 or (select issue from automation.lock_mirror_records where source_org_id='org_MirrorQA' and source_lock_id='lock_QAC')<>'source_record_missing' then raise exception 'FAIL missing source row deleted inventory';end if;
  end if;
  if not exists(select 1 from public.action_items where cause_key='mirror_qa_damage' and state='open') then raise exception 'FAIL physical inspection issue dismissed';end if;
 end loop;
 if exists(select 1 from public.activity where facility_id='97000000-0000-0000-0000-000000000001' and (before_values::text||after_values::text) like '%00-A 01%') then raise exception 'FAIL audit contains plaintext';end if;
 if has_table_privilege('anon','automation.lock_mirror_records','select') or has_function_privilege('authenticated','automation.lock_mirror_batch(uuid,jsonb)','execute') then raise exception 'FAIL public sensitive access';end if;
 update automation.lock_mirror_control set mode='msl_authoritative' where id;
 if automation.lock_mirror_worker('lock_mirror_claim',jsonb_build_object('owner',owner_id,'force',true)) is not null then raise exception 'FAIL future cutover switch';end if;
end $$;
rollback;
select 'PASS: immutable matching, additions, assignment/history changes, exact encrypted combination, stale/version guards, local conflicts, uncertain SMS, no deletion, physical issues preserved and cutover boundary; all fixtures rolled back' as result;
