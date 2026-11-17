-- Isolated fixtures. Run with the migration inside BEGIN ... ROLLBACK.
insert into auth.users(id,email) values('98000000-0000-0000-0000-000000000001','action-gate@example.invalid');
insert into public.profiles(id,email,name,role) values('98000000-0000-0000-0000-000000000001','action-gate@example.invalid','Action Gate Fixture','employee');
insert into auth.sessions(id,user_id,created_at) values('98000000-0000-0000-0000-000000000002','98000000-0000-0000-0000-000000000001',clock_timestamp());
insert into public.facilities(id,name,identifier) values('98000000-0000-0000-0000-000000000003','Action Gate Fixture','ACTION-GATE-QA');
insert into public.memberships values('98000000-0000-0000-0000-000000000001','98000000-0000-0000-0000-000000000003');
insert into private.walkthrough_sources values('98000000-0000-0000-0000-000000000003','[{"unitId":"gate1","label":"GATE1","kind":"occupied","tenantName":"Isolated Fixture"},{"unitId":"gate2","label":"GATE2","kind":"overlock"},{"unitId":"gate3","label":"GATE3","kind":"vacant"}]','cubby',clock_timestamp());
insert into private.walkthrough_policies(facility_id,vacant_required) values('98000000-0000-0000-0000-000000000003',true);
create temp table gate_baseline as select
 (select count(*) from public.action_items) as actions,
 (select md5(string_agg(id::text,',' order by id)) from public.action_items) as action_ids,
 (select count(*) from public.locks) as locks,
 (select count(*) from public.assignments) as assignments,
 (select md5(pg_get_functiondef('automation.lock_mirror_batch(uuid,jsonb)'::regprocedure))) as mirror_function,
 (select md5(pg_get_functiondef('automation.scheduled_tick()'::regprocedure))) as scheduler_function;
-- Seed a historical fixture without enabling generation; no user data is edited.
alter table public.action_items disable trigger manager_action_generation_gate;
insert into public.action_items(id,facility_id,cause_key,kind,title,detail,state)
 values('98000000-0000-0000-0000-000000000004','98000000-0000-0000-0000-000000000003','gate:historical','sync_failure','Historical fixture','Preserve this record','resolved');
alter table public.action_items enable trigger manager_action_generation_gate;
create temp table gate_history as select to_jsonb(a) as snapshot from public.action_items a where id='98000000-0000-0000-0000-000000000004';
do $$declare kind text;begin
 if automation.manager_actions_enabled() then raise exception 'FAIL mirror generation enabled';end if;
 foreach kind in array array['overlock_removal','vacant_recovery','missing_assignment','sms_failure','assignment_conflict','sync_failure','walkthrough_issue','walkthrough_missing'] loop
  perform automation.task('gate:'||kind,'98000000-0000-0000-0000-000000000003',kind,'Fixture','No operational data');
 end loop;
 perform automation.task('gate:historical','98000000-0000-0000-0000-000000000003','sync_failure','Changed fixture','Must not reopen');
 update public.action_items set state='open' where id='98000000-0000-0000-0000-000000000004';
 perform private.walkthrough_missing('98000000-0000-0000-0000-000000000003');
 if (select count(*) from public.action_items)<>(select actions+1 from gate_baseline) then raise exception 'FAIL background task creation';end if;
 if (select to_jsonb(a) from public.action_items a where id='98000000-0000-0000-0000-000000000004') is distinct from (select snapshot from gate_history) then raise exception 'FAIL historical item changed';end if;
end $$;
select set_config('request.jwt.claims','{"sub":"98000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"98000000-0000-0000-0000-000000000002"}',true);
set local role authenticated;
do $$declare p jsonb;e jsonb;r jsonb;denied boolean:=false;begin
 perform public.manager_session(false);
 p:=public.walkthrough_page('98000000-0000-0000-0000-000000000003');e:=p->'items'->0;
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_issue','issue','Door/Latch Damage'));e:=r->'entry';
 if e->>'issue'<>'Door/Latch Damage' or (e->>'confirmed')::boolean then raise exception 'FAIL issue save independent';end if;
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_confirmation','confirmed',true));
 if r->'entry'->>'issue'<>'Door/Latch Damage' or not (r->'entry'->>'confirmed')::boolean then raise exception 'FAIL confirmation/issue persistence';end if;
 if public.automation_dashboard('98000000-0000-0000-0000-000000000003')->'items'<>'[]'::jsonb then raise exception 'FAIL dashboard exposure';end if;
 if exists(select 1 from public.action_items) then raise exception 'FAIL historical rows exposed';end if;
 begin perform public.automation_action(jsonb_build_object('id','98000000-0000-0000-0000-000000000004','action','resolve'));exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'FAIL legacy manager controls enabled';end if;
 if not private.can_access('98000000-0000-0000-0000-000000000003') then raise exception 'FAIL facility access changed';end if;
end $$;
reset role;
-- A mode change alone never activates tasks. A flag change cannot override Mirror Mode.
update automation.lock_mirror_control set mode='msl_authoritative',action_items_enabled=false where id;
do $$begin if automation.manager_actions_enabled() then raise exception 'FAIL automatic cutover activation';end if;end $$;
update automation.lock_mirror_control set mode='mirror',action_items_enabled=true where id;
do $$begin if automation.manager_actions_enabled() then raise exception 'FAIL mirror flag override';end if;end $$;
update automation.lock_mirror_control set action_items_enabled=false where id;
do $$begin
 if (select count(*) from public.action_items)<>(select actions+1 from gate_baseline) then raise exception 'FAIL inspection task generated';end if;
 if (select count(*) from public.locks)<>(select locks from gate_baseline) or (select count(*) from public.assignments)<>(select assignments from gate_baseline) then raise exception 'FAIL inventory mutated';end if;
 if md5(pg_get_functiondef('automation.lock_mirror_batch(uuid,jsonb)'::regprocedure))<>(select mirror_function from gate_baseline) or md5(pg_get_functiondef('automation.scheduled_tick()'::regprocedure))<>(select scheduler_function from gate_baseline) then raise exception 'FAIL sync implementation changed';end if;
 if not exists(select 1 from private.walkthrough_events where issue='Door/Latch Damage' and actor_id='98000000-0000-0000-0000-000000000001') then raise exception 'FAIL inspection audit missing';end if;
end $$;
