-- Focused acceptance for this release only. Caller wraps migration + these fixtures in BEGIN/ROLLBACK.
insert into auth.users(id,email) values('81000000-0000-0000-0000-000000000001','lock-edit-qa@example.invalid');
insert into public.profiles(id,email,name,role) values('81000000-0000-0000-0000-000000000001','lock-edit-qa@example.invalid','Lock Edit QA','employee');
insert into auth.sessions(id,user_id) values('82000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000001');
insert into public.facilities(id,name,identifier) values('83000000-0000-0000-0000-000000000001','Lock Edit QA A','LOCK-EDIT-QA-A'),('83000000-0000-0000-0000-000000000002','Lock Edit QA B','LOCK-EDIT-QA-B');
insert into public.memberships values('81000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001');
insert into public.locks(id,serial,color,facility_id,status) values('84000000-0000-0000-0000-000000000002','EDITQOTHERB','Unknown','83000000-0000-0000-0000-000000000002','unclassified');
insert into public.locks(serial,color,facility_id,status) select 'EDITQ'||replace(status,'_',''),'Unknown','83000000-0000-0000-0000-000000000001',status from unnest(array['unclassified','tenant_held','maintenance']) status;
select set_config('request.jwt.claims','{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"82000000-0000-0000-0000-000000000001"}',true);
set local role authenticated;
do $$declare lid uuid;r jsonb;denied boolean;begin
lid:=public.mutate_lock('{"action":"create","serial":"EDITQ001","combination":"FIXTURE-OLD-ONLY","color":"Green","facility_id":"83000000-0000-0000-0000-000000000001"}');
perform set_config('lock_edit_qa.lock',lid::text,true);
perform public.mutate_lock(jsonb_build_object('action','assign','id',lid,'version',1,'status','overlock','unit','QA-001'));
perform public.mutate_lock(jsonb_build_object('action','edit','id',lid,'version',2,'color','Black','notes','Fixture ordinary edit'));
denied:=false;begin perform public.mutate_lock(jsonb_build_object('action','edit','id',lid,'version',3,'serial','CHANGED','color','Red'));exception when sqlstate '22023' then denied:=true;end;if not denied then raise exception 'FAIL serial edit';end if;
denied:=false;begin perform public.mutate_lock(jsonb_build_object('action','edit','id',lid,'version',3,'combination','DIRECT-EDIT','color','Red'));exception when sqlstate '22023' then denied:=true;end;if not denied then raise exception 'FAIL ordinary combination edit';end if;
for r in select value from jsonb_array_elements('[{"combination":"001A--z","confirm_combination":"01A--z","physical_verified":true},{"combination":"001A--z","confirm_combination":"001A--z","physical_verified":false},{"combination":"","confirm_combination":"","physical_verified":true},{"combination":"001A--z","physical_verified":true}]') loop
 denied:=false;begin perform public.mutate_lock(r||jsonb_build_object('action','change_combination','id',lid,'version',3));exception when sqlstate '22023' then denied:=true;end;if not denied then raise exception 'FAIL combination confirmation guard';end if;
end loop;
denied:=false;begin perform public.mutate_lock(jsonb_build_object('action','change_combination','id',lid,'version',2,'combination','001A--z','confirm_combination','001A--z','physical_verified',true));exception when serialization_failure then denied:=true;end;if not denied then raise exception 'FAIL stale record guard';end if;
denied:=false;begin perform public.mutate_lock('{"action":"change_combination","id":"84000000-0000-0000-0000-000000000002","version":1,"combination":"x","confirm_combination":"x","physical_verified":true}');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL unauthorized combination change';end if;
r:=public.inventory_listing('EDITQ',null,array['unclassified','tenant_held','maintenance'],'facility_serial',100,0);
if (r->>'total')::int<>3 then raise exception 'FAIL Other authorized filter';end if;
if exists(select 1 from jsonb_array_elements(r->'items') x where x ?| array['source_lock_id','source_org_id','imported_at','last_assigned_by','created_at','updated_at']) then raise exception 'FAIL technical inventory metadata';end if;
if not public.has_current_assignment(lid) then raise exception 'FAIL current operational assignment';end if;
denied:=false;begin perform 1 from public.activity limit 1;exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL browser audit exposure';end if;
denied:=false;begin perform 1 from public.assignments limit 1;exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL browser assignment audit exposure';end if;
denied:=false;begin perform source_lock_id from public.locks limit 1;exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL direct source metadata';end if;
end $$;
reset role;
-- Queue fixtures never reach a provider and never change production SMS configuration.
update public.locks set source_org_id='org_EDITQA',source_lock_id='lock_EDITQA' where id=current_setting('lock_edit_qa.lock')::uuid;
insert into automation.operational_snapshots(lease_id,source_org_id,source_facility_id,source_unit_id,customer_id,facts) values('lease_EDITQA','org_EDITQA','fac_EDITQA','unit_EDITQA','customer_EDITQA','{}');
insert into automation.sms_consents(id,facility_id,customer_id,phone_hash,purpose,proof_source,proof_version,granted_at,recorded_by) values('85000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','customer_EDITQA','fixture-only','lock_access','fixture','fixture',now(),'81000000-0000-0000-0000-000000000001');
insert into automation.notification_outbox(id,dedupe_key,kind,facility_id,lease_id,customer_id,source_unit_id,assignment_id,lock_id,lock_version,phone_hash,consent_id,episode_id,template_version,source_occurred_at,state)
select '86000000-0000-0000-0000-000000000001','EDIT-QA-PENDING','overlock_clearance',a.facility_id,'lease_EDITQA','customer_EDITQA','unit_EDITQA',a.id,a.lock_id,3,'fixture-only','85000000-0000-0000-0000-000000000001','episode_EDITQA','fixture',now(),'pending' from public.assignments a where lock_id=current_setting('lock_edit_qa.lock')::uuid and released_at is null;
set local role authenticated;
do $$begin perform public.mutate_lock(jsonb_build_object('action','change_combination','id',current_setting('lock_edit_qa.lock'),'version',3,'combination',' 001A--z ','confirm_combination',' 001A--z ','physical_verified',true));end $$;
reset role;
do $$declare l public.locks;a public.activity;begin
select * into l from public.locks where id=current_setting('lock_edit_qa.lock')::uuid;
if l.serial<>'EDITQ001' or l.source_lock_id<>'lock_EDITQA' or l.status<>'overlock' or l.unit<>'QA-001' or l.color<>'Black' or l.notes<>'Fixture ordinary edit' or l.version<>4 then raise exception 'FAIL physical record changed unexpectedly';end if;
if (select extensions.pgp_sym_decrypt(encrypted,(select value from private.encryption_key)) from private.lock_secrets where lock_id=l.id)<>' 001A--z ' then raise exception 'FAIL exact encrypted round trip';end if;
if not exists(select 1 from automation.notification_outbox where id='86000000-0000-0000-0000-000000000001' and state='cancelled' and error_code='combination_changed') then raise exception 'FAIL pending notification cancellation';end if;
if not exists(select 1 from automation.notification_attempts where notification_id='86000000-0000-0000-0000-000000000001' and state='cancelled') then raise exception 'FAIL notification audit';end if;
select * into a from public.activity where lock_id=l.id and action='change_combination';
if a.actor_id is distinct from '81000000-0000-0000-0000-000000000001'::uuid or a.facility_id<>l.facility_id or a.created_at is null or a.before_values is null or a.after_values is null then raise exception 'FAIL secure combination audit';end if;
if a.before_values::text like '%001A--z%' or a.after_values::text like '%001A--z%' or a.before_values::text like '%FIXTURE-OLD-ONLY%' or a.after_values::text like '%FIXTURE-OLD-ONLY%' then raise exception 'FAIL plaintext in audit';end if;
end $$;
-- A reserved or uncertain provider attempt prevents a subsequent change.
update automation.notification_outbox set state='dispatching' where id='86000000-0000-0000-0000-000000000001';
set local role authenticated;
do $$declare denied boolean:=false;r jsonb;begin
begin perform public.mutate_lock(jsonb_build_object('action','change_combination','id',current_setting('lock_edit_qa.lock'),'version',4,'combination','REPLACEMENT','confirm_combination','REPLACEMENT','physical_verified',true));exception when lock_not_available then denied:=true;end;if not denied then raise exception 'FAIL dispatching combination guard';end if;
r:=public.automation_dashboard(null);
if r ?| array['mode','readiness','lastSyncAt','errorCode','lastTickAt'] then raise exception 'FAIL integration diagnostics';end if;
if exists(select 1 from jsonb_array_elements(r->'items') x where x ?| array['assignment_id','notification_id','created_at','updated_at','cause_key']) then raise exception 'FAIL operational item metadata';end if;
end $$;
reset role;
update automation.notification_outbox set state='unknown' where id='86000000-0000-0000-0000-000000000001';
set local role authenticated;
do $$declare denied boolean:=false;begin
begin perform public.mutate_lock(jsonb_build_object('action','change_combination','id',current_setting('lock_edit_qa.lock'),'version',4,'combination','REPLACEMENT','confirm_combination','REPLACEMENT','physical_verified',true));exception when lock_not_available then denied:=true;end;if not denied then raise exception 'FAIL uncertain provider guard';end if;
end $$;
reset role;
select 'PASS: Other filtering, read-only serial, separate exact combination change, acknowledgment, concurrency, authorization, encrypted audit, pending cancellation, in-flight protection, backend-only audit and diagnostics' as result;
