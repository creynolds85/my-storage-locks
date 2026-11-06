-- Caller wraps in BEGIN/ROLLBACK. Fixture identities/codes only; never calls Twilio.
insert into auth.users(id,email) values('71000000-0000-0000-0000-000000000001','tenant-request-qa@example.invalid');
insert into public.profiles(id,email,name,role) values('71000000-0000-0000-0000-000000000001','tenant-request-qa@example.invalid','Tenant Request QA','employee');
insert into public.facilities(id,name,identifier,source_org_id,source_facility_id) values('73000000-0000-0000-0000-000000000001','Tenant QA Facility','TENANT-REQUEST-QA','org_TENANTQA','fac_TENANTQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id,return_instructions) values('org_TENANTQA','fac_TENANTQA','73000000-0000-0000-0000-000000000001','the controlled test drop box');
insert into public.locks(id,serial,color,facility_id,status,unit) values('74000000-0000-0000-0000-000000000001','TENANTQA001','Green','73000000-0000-0000-0000-000000000001','vacant','QA001');
insert into private.lock_secrets values('74000000-0000-0000-0000-000000000001',extensions.pgp_sym_encrypt('DISPOSABLE-TENANT-QA',(select value from private.encryption_key)));
insert into public.assignments(id,lock_id,facility_id,unit,type,assigned_by,assigned_at) values('75000000-0000-0000-0000-000000000001','74000000-0000-0000-0000-000000000001','73000000-0000-0000-0000-000000000001','QA001','vacant',null,null);
insert into automation.unit_links(source_org_id,source_facility_id,source_unit_id,facility_id,label) values('org_TENANTQA','fac_TENANTQA','unit_TENANTQA','73000000-0000-0000-0000-000000000001','QA001');
insert into automation.assignment_links values('75000000-0000-0000-0000-000000000001','org_TENANTQA','unit_TENANTQA',now());
do $$declare n automation.notification_outbox;request_id uuid;notice_id uuid;intake jsonb;accepted jsonb;r jsonb;facts jsonb;verify jsonb;consent_id uuid;count_before int;begin
intake:=jsonb_build_object('facility',left(encode(extensions.digest('73000000-0000-0000-0000-000000000001','sha256'),'hex'),24),'unit','QA001','phoneDigest',encode(extensions.digest('+17045550100','sha256'),'hex'),'phoneRateHash',repeat('a',64),'ipHash',repeat('b',64),'unitHash',repeat('c',64),'dedupeKey',repeat('d',64),'nonceHash',repeat('e',64));
accepted:=automation.tenant_request_worker('tenant_intake',intake);request_id:=(accepted->>'requestId')::uuid;
if request_id is null or accepted->>'eventId' is null then raise exception 'FAIL durable intake';end if;
perform set_config('tenant_qa.request',request_id::text,true);
if automation.tenant_request_worker('tenant_intake',intake) is not null then raise exception 'FAIL duplicate intake';end if;
if automation.tenant_request_worker('tenant_intake',intake||jsonb_build_object('dedupeKey',repeat('f',64),'nonceHash',repeat('1',64))) is not null then raise exception 'FAIL cooldown';end if;
if (select extensions.pgp_sym_decrypt(unit_encrypted,(select value from private.encryption_key)) from automation.tenant_requests where id=request_id)<>'QA001' then raise exception 'FAIL encrypted input';end if;
for i in 1..5 loop
 r:=automation.tenant_request_worker('tenant_intake',intake||jsonb_build_object('unit','OTHER'||i,'unitHash',encode(extensions.digest('unit'||i,'sha256'),'hex'),'phoneRateHash',encode(extensions.digest('phone'||i,'sha256'),'hex'),'dedupeKey',encode(extensions.digest('dedupe'||i,'sha256'),'hex'),'nonceHash',encode(extensions.digest('nonce'||i,'sha256'),'hex')));
 if r is null then raise exception 'FAIL below-limit intake';end if;
end loop;
r:=automation.tenant_request_worker('tenant_intake',intake||jsonb_build_object('unit','LIMIT','unitHash',repeat('2',64),'phoneRateHash',repeat('3',64),'dedupeKey',repeat('4',64),'nonceHash',repeat('5',64)));
if r is not null then raise exception 'FAIL IP limit';end if;
r:=automation.tenant_request_worker('tenant_directory','{}');
if r->>'liveApproved'<>'false' or exists(select 1 from jsonb_array_elements(r->'facilities') f where f ?| array['facility_id','source_org_id','source_facility_id','unit','combination']) then raise exception 'FAIL public directory exposure';end if;
facts:=jsonb_build_object('leaseId','lease_TENANTQA','facilityId','fac_TENANTQA','unitId','unit_TENANTQA','customerId','customer_TENANTQA','verified',true,'verifiedAt',now(),'occurredAt',now(),'active',true,'paymentClear',true,'auctionClear',true,'restrictionsClear',true,'overlockNeeded',false,'rentalCompleted',false,'rentalAccessReady',true,'releaseAccessReady',true,'requirementsSatisfied',true,'moveInAllowed',true);
insert into automation.operational_snapshots(lease_id,source_org_id,source_facility_id,source_unit_id,customer_id,facts,phone_encrypted,phone_hash,suppressed,unit_label,facility_name)
values('lease_TENANTQA','org_TENANTQA','fac_TENANTQA','unit_TENANTQA','customer_TENANTQA',facts,extensions.pgp_sym_encrypt('+17045550100',(select value from private.encryption_key)),encode(extensions.digest('+17045550100','sha256'),'hex'),false,'QA001','Tenant QA Facility');
insert into automation.sms_consents(facility_id,customer_id,phone_hash,purpose,proof_source,proof_version,granted_at,recorded_by) values('73000000-0000-0000-0000-000000000001','customer_TENANTQA',encode(extensions.digest('+17045550100','sha256'),'hex'),'lock_access','controlled fixture','fixture',now(),'71000000-0000-0000-0000-000000000001') returning id into consent_id;
verify:=jsonb_build_object('id',request_id,'leaseId','lease_TENANTQA','assignmentId','75000000-0000-0000-0000-000000000001','lockId','74000000-0000-0000-0000-000000000001','lockVersion',1);
r:=automation.tenant_request_worker('tenant_verify',verify);if r->>'verified'<>'true' then raise exception 'FAIL verified request %',r;end if;
r:=automation.tenant_request_worker('tenant_enqueue',verify||jsonb_build_object('consentId',consent_id,'templateVersion','2026-11-05-draft-1'));notice_id:=(r->>'id')::uuid;
if notice_id is null or r->>'state'<>'dry_run' then raise exception 'FAIL dry run notification %',r;end if;
if not exists(select 1 from automation.notification_outbox where id=notice_id and initiator='tenant_request' and tenant_request_id=request_id) then raise exception 'FAIL initiator audit';end if;
if (select mode from automation.settings where id)<>'dry_run' or (select tenant_requests_approved_at from automation.settings where id) is not null then raise exception 'FAIL production live gate changed';end if;
select count(*) into count_before from public.action_items where assignment_id='75000000-0000-0000-0000-000000000001' and kind='vacant_recovery' and state='open';
if count_before<>1 then raise exception 'FAIL recovery task';end if;
if (select status from public.locks where id='74000000-0000-0000-0000-000000000001')<>'vacant' or exists(select 1 from public.assignments where id='75000000-0000-0000-0000-000000000001' and released_at is not null) then raise exception 'FAIL physical release';end if;
-- A new, reverified request can repeat a previously delivered notification after cooldown.
update automation.tenant_requests set created_at=now()-interval '11 minutes' where id=request_id;
update automation.notification_outbox set state='delivered' where id=notice_id;
accepted:=automation.tenant_request_worker('tenant_intake',intake||jsonb_build_object('ipHash',repeat('6',64),'dedupeKey',repeat('7',64),'nonceHash',repeat('8',64)));request_id:=(accepted->>'requestId')::uuid;
if request_id is null then raise exception 'FAIL legitimate repeat intake';end if;
verify:=verify||jsonb_build_object('id',request_id);
perform automation.tenant_request_worker('tenant_verify',verify);
r:=automation.tenant_request_worker('tenant_enqueue',verify||jsonb_build_object('consentId',consent_id,'templateVersion','2026-11-05-draft-1'));notice_id:=(r->>'id')::uuid;
if notice_id is null then raise exception 'FAIL legitimate repeat queue';end if;
if (select count(*) from public.action_items where assignment_id='75000000-0000-0000-0000-000000000001' and kind='vacant_recovery' and state='open')<>1 then raise exception 'FAIL duplicate recovery task';end if;
-- Version, source and approval checks are exercised without ever enabling a live mode.
select * into n from automation.notification_outbox where id=notice_id;
if not automation.is_current(n) then raise exception 'FAIL current request binding';end if;
update public.locks set version=2 where id='74000000-0000-0000-0000-000000000001';
if automation.is_current(n) then raise exception 'FAIL changed combination version';end if;
update public.locks set version=1 where id='74000000-0000-0000-0000-000000000001';
update automation.operational_snapshots set suppressed=true where lease_id='lease_TENANTQA';
if automation.is_current(n) then raise exception 'FAIL final suppression check';end if;
update automation.operational_snapshots set suppressed=false where lease_id='lease_TENANTQA';
update automation.notification_outbox set state='unknown' where id=notice_id;
update automation.tenant_requests set created_at=now()-interval '11 minutes' where id=request_id;
accepted:=automation.tenant_request_worker('tenant_intake',intake||jsonb_build_object('ipHash',repeat('9',64),'dedupeKey',repeat('0',64),'nonceHash',encode(extensions.digest('third-nonce','sha256'),'hex')));request_id:=(accepted->>'requestId')::uuid;
verify:=verify||jsonb_build_object('id',request_id);perform automation.tenant_request_worker('tenant_verify',verify);
r:=automation.tenant_request_worker('tenant_enqueue',verify||jsonb_build_object('consentId',consent_id,'templateVersion','2026-11-05-draft-1'));
if r is not null or not exists(select 1 from automation.tenant_requests where id=request_id and reason='previous_delivery_unresolved') then raise exception 'FAIL uncertain outcome resend';end if;
if exists(select 1 from automation.notification_attempts where notification_id=notice_id and to_jsonb(notification_attempts)::text like '%DISPOSABLE-TENANT-QA%') then raise exception 'FAIL plaintext audit';end if;
-- The same current-assignment guard and recovery helper retain automatic behavior.
update automation.notification_outbox set state='failed' where id=notice_id;
update public.assignments set assigned_at=now()-interval '1 hour' where id='75000000-0000-0000-0000-000000000001';
update automation.operational_snapshots snapshot_row set facts=snapshot_row.facts||jsonb_build_object('episodeId','auto_TENANTQA','rentalCompleted',true,'occurredAt',now()) where lease_id='lease_TENANTQA';
n.initiator:='automatic';n.tenant_request_id:=null;n.episode_id:='auto_TENANTQA';
if not automation.is_current(n) then raise exception 'FAIL automatic workflow compatibility';end if;
perform automation.recovery_task(n);
if (select count(*) from public.action_items where assignment_id='75000000-0000-0000-0000-000000000001' and kind='vacant_recovery' and state='open')<>1 then raise exception 'FAIL shared automatic recovery task';end if;

end $$;
set local role anon;
do $$declare denied boolean:=false;begin
begin perform 1 from automation.tenant_requests;exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL public request record access';end if;
denied:=false;begin perform automation.tenant_request_worker('tenant_directory','{}');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL unauthenticated worker helper';end if;
end $$;
reset role;
select 'PASS: encrypted durable intake, duplicate/rate/cooldown controls, source/assignment binding, separate approval gates, consent, repeat requests, uncertain outcomes, shared recovery, unchanged physical assignments and automatic compatibility' as result;
