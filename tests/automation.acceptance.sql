-- Run only inside BEGIN/ROLLBACK, after the infrastructure migration. All identities and codes are fixtures.
insert into auth.users(id,email) values('10000000-0000-0000-0000-000000000001','automation-admin@example.invalid'),('10000000-0000-0000-0000-000000000002','automation-employee@example.invalid'),('10000000-0000-0000-0000-000000000003','automation-other@example.invalid');
insert into public.profiles(id,email,name,role) values('10000000-0000-0000-0000-000000000001','automation-admin@example.invalid','Test Admin','admin'),('10000000-0000-0000-0000-000000000002','automation-employee@example.invalid','Test Employee','employee'),('10000000-0000-0000-0000-000000000003','automation-other@example.invalid','Other','employee');
insert into auth.sessions(id,user_id) values('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002'),('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003');
insert into public.facilities(id,name,identifier) values('30000000-0000-0000-0000-000000000001','Test Facility A','AUTO-A'),('30000000-0000-0000-0000-000000000002','Test Facility B','AUTO-B');
insert into public.memberships values('10000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001'),('10000000-0000-0000-0000-000000000003','30000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"20000000-0000-0000-0000-000000000001"}',true);
update automation.settings set worker_token_hash=encode(extensions.digest(repeat('fixture-only-token',4),'sha256'),'hex'),baseline_complete=true,evaluation_started_at=now()-interval '1 hour';
select public.automation_map_facility('{"orgId":"org_TEST","sourceFacilityId":"fac_TEST","facilityId":"30000000-0000-0000-0000-000000000001","returnInstructions":"the test drop box"}');
do $$declare lid uuid;aid uuid;cid uuid;r jsonb;n automation.notification_outbox;fixture_token text:=repeat('fixture-only-token',4);args jsonb;denied boolean;begin
lid:=public.mutate_lock('{"action":"create","serial":"FIXTURE01","combination":"TEST-CODE-ONLY","color":"Green","facility_id":"30000000-0000-0000-0000-000000000001"}');
perform public.mutate_lock(jsonb_build_object('action','assign','id',lid,'version',1,'status','overlock','unit','001A'));
select id into aid from public.assignments where lock_id=lid and released_at is null;
perform public.automation_worker(fixture_token,'units_save','{"orgId":"org_TEST","units":[{"unitId":"unit_TEST","facilityId":"fac_TEST","name":"001A","operationalState":{"free":false,"reserved":false,"leaseId":"lease_TEST"}}]}');
perform public.automation_worker(fixture_token,'snapshot_save',jsonb_build_object('orgId','org_TEST','sourceVersion',now(),'unitLabel','001A','facilityName','Test Facility A','recipient',jsonb_build_object('phone','+17045550100','suppressed',false),'facts',jsonb_build_object('leaseId','lease_TEST','facilityId','fac_TEST','unitId','unit_TEST','customerId','customer_TEST','verified',true,'verifiedAt',now(),'occurredAt',now(),'active',true,'overlockNeeded',false,'paymentClear',true,'auctionClear',true,'restrictionsClear',true,'clearanceTransition',true,'episodeId','episode_TEST')));
r:=public.automation_record_consent(jsonb_build_object('facilityId','30000000-0000-0000-0000-000000000001','leaseId','lease_TEST','proofSource','controlled fixture','proofVersion','test-1','grantedAt',now()));cid:=(r->>'id')::uuid;
r:=public.automation_worker(fixture_token,'context','{"leaseId":"lease_TEST"}');
if (select operational_state->>'leaseId' from automation.unit_links where source_unit_id='unit_TEST')<>'lease_TEST' then raise exception 'FAIL unit operational cache';end if;
if jsonb_array_length(r->'assignments')<>1 or r->'consent'->>'proofId'<>cid::text then raise exception 'FAIL mapping/consent';end if;
args:=jsonb_build_object('key','fixture-notification','kind','overlock_clearance','leaseId','lease_TEST','assignmentId',aid,'lockId',lid,'lockVersion',2,'consentId',cid,'episodeId','episode_TEST','templateVersion','2026-11-05-draft-1');
r:=public.automation_worker(fixture_token,'enqueue',args);
if r->>'state'<>'dry_run' or r->>'id' is null then raise exception 'FAIL dry-run enqueue %',r;end if;
perform public.automation_worker(fixture_token,'enqueue',args);
if (select count(*) from automation.notification_outbox)<>1 or (select count(*) from public.action_items where kind='overlock_removal')<>1 then raise exception 'FAIL duplicate';end if;
if public.automation_worker(fixture_token,'outbox_claim','{}') is not null then raise exception 'FAIL live latch';end if;
if (select status from public.locks where id=lid)<>'overlock' then raise exception 'FAIL premature release';end if;
if public.automation_dashboard(null)::text like '%TEST-CODE-ONLY%' then raise exception 'FAIL dashboard secret';end if;
-- Controlled, rolled-back live gate exercises the dispatch transaction, with no provider call.
update automation.settings set mode='live',acceptance_passed=true,live_approved_at=now(),activation_at=now()-interval '1 minute',policy_version='2026-11-05-draft-1';
update automation.notification_outbox set state='pending';
r:=public.automation_worker(fixture_token,'outbox_claim','{}');
if r->>'combination'<>'TEST-CODE-ONLY' or r->>'attemptId' is null then raise exception 'FAIL reserved dispatch';end if;
perform public.automation_worker(fixture_token,'delivery_callback',jsonb_build_object('attemptId',r->>'attemptId','providerSid','SM00000000000000000000000000000000','state','delivered'));
perform public.automation_worker(fixture_token,'outbox_result',jsonb_build_object('attemptId',r->>'attemptId','providerSid','SM00000000000000000000000000000000','state','queued'));
select * into n from automation.notification_outbox;
if n.state<>'delivered' or n.delivery_status<>'delivered' or n.delivered_at is null then raise exception 'FAIL callback ordering';end if;
if (select status from public.locks where id=lid)<>'overlock' then raise exception 'FAIL SMS release';end if;
-- Fresh assignment changes cancel a pending message before secret retrieval.
update automation.notification_outbox set state='pending',attempt_id=null,provider_sid=null;
perform public.mutate_lock(jsonb_build_object('action','edit','id',lid,'version',2,'serial','FIXTURE01','color','Black'));
r:=public.automation_worker(fixture_token,'outbox_claim','{}');
if r->>'cancelled'<>'true' or r ? 'combination' then raise exception 'FAIL assignment recheck';end if;
-- A stopped recipient is revoked without releasing the physical lock.
perform public.automation_worker(fixture_token,'suppress',jsonb_build_object('phoneHash',encode(extensions.digest('+17045550100','sha256'),'hex'),'providerSid','SMSTOPFIXTURE'));
if exists(select 1 from automation.sms_consents where id=cid and revoked_at is null) then raise exception 'FAIL suppression';end if;
if (select status from public.locks where id=lid)<>'overlock' then raise exception 'FAIL STOP release';end if;
end $$;
select set_config('automation.fixture_action',(select id::text from public.action_items where kind='overlock_removal'),true);
set local role anon;
do $$declare denied boolean:=false;begin
begin perform public.automation_worker('incorrect','outbox_claim','{}');exception when insufficient_privilege then denied:=true;end;
if not denied then raise exception 'FAIL worker authentication';end if;
denied:=false;begin perform 1 from automation.notification_outbox;exception when insufficient_privilege then denied:=true;end;
if not denied then raise exception 'FAIL anonymous data exposure';end if;
denied:=false;begin perform automation.task('bypass',null,'sync_failure','x','x');exception when insufficient_privilege then denied:=true;end;
if not denied then raise exception 'FAIL private mutation exposure';end if;
end $$;
reset role;
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated","session_id":"20000000-0000-0000-0000-000000000003"}',true);
set local role authenticated;
do $$declare denied boolean:=false;begin
if jsonb_array_length(public.automation_dashboard(null)->'items')<>0 then raise exception 'FAIL facility action isolation';end if;
begin perform public.automation_action(jsonb_build_object('id',(select current_setting('automation.fixture_action',true)),'action','confirm_recovery'));exception when others then denied:=true;end;
if not denied then raise exception 'FAIL cross-facility recovery';end if;
end $$;
reset role;
-- Staff physical confirmation is the only path that releases this fixture lock.
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated","session_id":"20000000-0000-0000-0000-000000000002"}',true);
select set_config('automation.fixture_action',(select id::text from public.action_items where kind='overlock_removal'),true);
set local role authenticated;
select public.automation_action(jsonb_build_object('id',current_setting('automation.fixture_action'),'action','confirm_recovery'));
reset role;
do $$begin
if (select status from public.locks where serial='FIXTURE01')<>'available' then raise exception 'FAIL physical confirmation';end if;
if not exists(select 1 from public.action_items where kind='overlock_removal' and recovered_at is not null and state='resolved') then raise exception 'FAIL recovery audit';end if;
if exists(select 1 from automation.notification_attempts where to_jsonb(notification_attempts)::text like '%TEST-CODE-ONLY%') then raise exception 'FAIL secret audit leak';end if;
end $$;
select 'PASS: dry-run gates, dedupe, encrypted secret claim, delivery ordering, assignment recheck, STOP, RLS and employee recovery' as acceptance_result;
