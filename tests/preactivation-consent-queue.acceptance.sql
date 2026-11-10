-- Execute inside BEGIN/ROLLBACK only. Completes the request-scoped consent ->
-- durable notification path added after the original tenant acceptance suite.
-- No live latches, real records, Twilio calls or production combinations are used.
do $$
declare f uuid:=gen_random_uuid();l uuid:=gen_random_uuid();a uuid:=gen_random_uuid();r uuid;cid uuid;nid uuid;
 org text:='preactivation-fixture-'||gen_random_uuid();fac text:='fac-'||gen_random_uuid();u text:='unit-'||gen_random_uuid();
 lease text:='lease-'||gen_random_uuid();customer text:='customer-'||gen_random_uuid();
 ph text:=encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');
 intake jsonb;reply jsonb;binding jsonb;n automation.notification_outbox;begin
 if (select mode from automation.settings where id)<>'dry_run'
  or (select live_approved_at from automation.settings where id) is not null
  or (select tenant_requests_approved_at from automation.settings where id) is not null then raise exception 'Dry-run gates required';end if;
 insert into public.facilities(id,name,identifier,source_org_id,source_facility_id) values(f,'Disposable Preactivation Fixture',f::text,org,fac);
 insert into automation.facility_links values(org,fac,f,'the controlled fixture return box');
 insert into public.locks(id,serial,color,facility_id,status,unit) values(l,'PREACTQA'||replace(l::text,'-',''),'Green',f,'vacant','QA001');
 insert into private.lock_secrets values(l,extensions.pgp_sym_encrypt('DISPOSABLE-PREACTIVATION-ONLY',(select value from private.encryption_key)));
 insert into public.assignments(id,lock_id,facility_id,unit,type,assigned_by,assigned_at) values(a,l,f,'QA001','vacant',null,null);
 insert into automation.assignment_links values(a,org,u,now());
 insert into automation.operational_snapshots(lease_id,source_org_id,source_facility_id,source_unit_id,customer_id,facts,phone_hash,suppressed,unit_label)
 values(lease,org,fac,u,customer,jsonb_build_object('verified',true,'verifiedAt',now(),'occurredAt',now(),'active',true,'paymentClear',true,'auctionClear',true,'restrictionsClear',true,'overlockNeeded',false,'rentalAccessReady',true,'requirementsSatisfied',true,'moveInAllowed',true),ph,false,'QA001');
 intake:=jsonb_build_object('facility',left(encode(extensions.digest(f::text,'sha256'),'hex'),24),'unit','QA001','phoneDigest',ph,'smsConsent',true,'consentVersion','2026-11-08-request-1');
 intake:=intake||jsonb_build_object('phoneRateHash',encode(extensions.digest(f::text||'phone','sha256'),'hex'),'ipHash',encode(extensions.digest(f::text||'ip','sha256'),'hex'),'unitHash',encode(extensions.digest(f::text||'unit','sha256'),'hex'),'dedupeKey',encode(extensions.digest(f::text||'dedupe','sha256'),'hex'),'nonceHash',encode(extensions.digest(f::text||'nonce','sha256'),'hex'));
 reply:=automation.tenant_request_worker('tenant_intake',intake);r:=(reply->>'requestId')::uuid;
 if r is null then raise exception 'FAIL combined intake';end if;
 reply:=automation.tenant_request_worker('tenant_consent_verify',jsonb_build_object('id',r,'leaseId',lease));cid:=(reply->>'proofId')::uuid;
 if cid is null then raise exception 'FAIL combined verified request receipt';end if;
 binding:=jsonb_build_object('id',r,'leaseId',lease,'assignmentId',a,'lockId',l,'lockVersion',1);
 reply:=automation.tenant_request_worker('tenant_verify',binding);
 if reply->>'verified'<>'true' then raise exception 'FAIL combined authorization';end if;
 reply:=automation.tenant_request_worker('tenant_enqueue',binding||jsonb_build_object('consentId',cid,'templateVersion','2026-11-05-draft-1'));nid:=(reply->>'id')::uuid;
 if nid is null or reply->>'state'<>'dry_run' then raise exception 'FAIL combined queue';end if;
 select * into n from automation.notification_outbox where id=nid;
 if not automation.is_current(n) then raise exception 'FAIL combined current assignment binding';end if;
 if (select count(*) from public.action_items where assignment_id=a and kind='vacant_recovery')<>1 then raise exception 'FAIL combined recovery task';end if;
 perform automation.tenant_request_worker('tenant_verify',binding);
 perform automation.tenant_request_worker('tenant_enqueue',binding||jsonb_build_object('consentId',cid,'templateVersion','2026-11-05-draft-1'));
 if (select count(*) from automation.notification_outbox where tenant_request_id=r)<>1 then raise exception 'FAIL combined duplicate';end if;
 if (select count(*) from automation.sms_consents where tenant_request_id=r)<>1 then raise exception 'FAIL duplicate request receipt';end if;
 update public.locks set version=version+1 where id=l;
 if automation.is_current(n) then raise exception 'FAIL queued request accepted stale combination version';end if;
 if (select status from public.locks where id=l)<>'vacant' or (select released_at from public.assignments where id=a) is not null then raise exception 'FAIL physical assignment changed';end if;
 if exists(select 1 from automation.notification_attempts where notification_id=nid and to_jsonb(notification_attempts)::text like '%DISPOSABLE-PREACTIVATION-ONLY%') then raise exception 'FAIL combination in audit';end if;
 if (select mode from automation.settings where id)<>'dry_run' then raise exception 'FAIL changed live gate';end if;
end $$;
select 'PASS: request-specific consent to durable dry-run queue, idempotency, recovery, current version and unchanged dispatch gates; all fixtures rolled back' result;
