-- Run inside BEGIN/ROLLBACK. Disposable fixtures; no real tenants, secrets or provider calls.
do $$
declare f uuid:=gen_random_uuid(); l uuid:=gen_random_uuid(); a uuid:=gen_random_uuid();r uuid;cid uuid;p jsonb;result jsonb;facts jsonb;n automation.notification_outbox;
 org text:='consent-fixture-'||gen_random_uuid()::text;fac text:='fac-'||gen_random_uuid()::text;u text:='unit-'||gen_random_uuid()::text;lease text:='lease-'||gen_random_uuid()::text;customer text:='customer-'||gen_random_uuid()::text;
 ph text:=encode(extensions.digest('+17045550100','sha256'),'hex');begin
 insert into public.facilities(id,name,identifier,source_org_id,source_facility_id) values(f,'Disposable Consent Fixture',f::text,org,fac);
 insert into automation.facility_links(source_org_id,source_facility_id,facility_id,return_instructions) values(org,fac,f,'fixture');
 insert into public.locks(id,serial,color,facility_id,status,unit) values(l,'CONSENTQA'||replace(l::text,'-',''),'Green',f,'vacant','QA001');
 insert into public.assignments(id,lock_id,facility_id,unit,type,assigned_by,assigned_at) values(a,l,f,'QA001','vacant',null,null);
 insert into automation.assignment_links values(a,org,u,now());
 p:=jsonb_build_object('facility',left(encode(extensions.digest(f::text,'sha256'),'hex'),24),'unit','QA001','phoneDigest',ph,
 'phoneRateHash',encode(extensions.digest(f::text||'phone','sha256'),'hex'),'ipHash',encode(extensions.digest(f::text||'ip','sha256'),'hex'),'unitHash',encode(extensions.digest(f::text||'unit','sha256'),'hex'),
 'dedupeKey',encode(extensions.digest(f::text||'dedupe','sha256'),'hex'),'nonceHash',encode(extensions.digest(f::text||'nonce','sha256'),'hex'),'smsConsent',true,'consentVersion','2026-11-08-request-1');
 result:=automation.tenant_request_worker('tenant_intake',p);r:=(result->>'requestId')::uuid;
 if r is null then raise exception 'FAIL consent intake';end if;
 if not exists(select 1 from automation.tenant_requests where id=r and sms_consent and consent_asserted_at=created_at and consent_verified_at is null) then raise exception 'FAIL assertion provenance';end if;
 if exists(select 1 from automation.sms_consents where tenant_request_id=r) then raise exception 'FAIL unverified intake granted consent';end if;
 p:=jsonb_build_object('id',r,'leaseId',lease);
 if automation.tenant_request_worker('tenant_consent_verify',p) is not null then raise exception 'FAIL missing source accepted';end if;
 facts:=jsonb_build_object('verified',true,'verifiedAt',now(),'active',true,'paymentClear',true,'auctionClear',true,'restrictionsClear',true,'overlockNeeded',false,'rentalAccessReady',true,'rentalCompleted',true,'requirementsSatisfied',true,'moveInAllowed',true,'episodeId','fixture-episode');
 insert into automation.operational_snapshots(lease_id,source_org_id,source_facility_id,source_unit_id,customer_id,facts,phone_hash,suppressed,unit_label) values(lease,org,fac,u,customer,facts,ph,false,'QA001');
 update automation.operational_snapshots set phone_hash=repeat('0',64) where lease_id=lease;
 if automation.tenant_request_worker('tenant_consent_verify',p) is not null then raise exception 'FAIL wrong phone accepted';end if;
 update automation.operational_snapshots set phone_hash=ph,observed_at=now()-interval '121 seconds' where lease_id=lease;
 if automation.tenant_request_worker('tenant_consent_verify',p) is not null then raise exception 'FAIL stale source accepted';end if;
 update automation.operational_snapshots set observed_at=now(),suppressed=true where lease_id=lease;
 if automation.tenant_request_worker('tenant_consent_verify',p) is not null then raise exception 'FAIL Cubby suppression accepted';end if;
 update automation.operational_snapshots set suppressed=false where lease_id=lease;
 -- Unique fixture hash prevents touching a real suppression record.
 update automation.tenant_requests set phone_digest=encode(extensions.digest(f::text||'fixture-phone','sha256'),'hex') where id=r;
 update automation.operational_snapshots set phone_hash=(select phone_digest from automation.tenant_requests where id=r) where lease_id=lease;
 insert into automation.sms_suppressions(phone_hash) select phone_digest from automation.tenant_requests where id=r;
 if automation.tenant_request_worker('tenant_consent_verify',p) is not null then raise exception 'FAIL local STOP bypass';end if;
 ph:=encode(extensions.digest('+17045550101','sha256'),'hex');
 update automation.tenant_requests set phone_digest=ph,sms_consent=false,consent_version=null,consent_asserted_at=null where id=r;
 update automation.operational_snapshots set phone_hash=ph where lease_id=lease;
 if automation.tenant_request_worker('tenant_consent_verify',p) is not null then raise exception 'FAIL unchecked accepted';end if;
 update automation.tenant_requests set sms_consent=true,consent_version='2026-11-08-request-1',consent_asserted_at=created_at where id=r;
 result:=automation.tenant_request_worker('tenant_consent_verify',p);cid:=(result->>'proofId')::uuid;
 if cid is null or not exists(select 1 from automation.sms_consents where id=cid and scope='request' and tenant_request_id=r and recorded_by is null and customer_id=customer and phone_hash=ph and proof_version='2026-11-08-request-1') then raise exception 'FAIL verified receipt';end if;
 perform automation.tenant_request_worker('tenant_consent_verify',p);
 if (select count(*) from automation.sms_consents where tenant_request_id=r)<>1 then raise exception 'FAIL duplicate receipt';end if;
 update automation.tenant_requests set state='verified',verified_at=now(),lease_id=lease,source_unit_id=u,customer_id=customer,snapshot_version=1,assignment_id=a,lock_id=l,lock_version=1 where id=r;
 n.facility_id:=f;n.assignment_id:=a;n.lock_id:=l;n.lock_version:=1;n.lease_id:=lease;n.customer_id:=customer;n.source_unit_id:=u;n.phone_hash:=ph;n.consent_id:=cid;n.kind:='new_rental';n.initiator:='tenant_request';n.tenant_request_id:=r;n.episode_id:='fixture-episode';n.source_occurred_at:=now();
 if not automation.is_current(n) then raise exception 'FAIL request-scoped receipt rejected';end if;
 n.initiator:='automatic';n.tenant_request_id:=null;
 if automation.is_current(n) then raise exception 'FAIL request consent leaked to automatic messages';end if;
 n.initiator:='tenant_request';n.tenant_request_id:=gen_random_uuid();
 if automation.is_current(n) then raise exception 'FAIL request consent reused for another request';end if;
 if has_function_privilege('anon','automation.tenant_request_worker(text,jsonb)','execute') or has_function_privilege('authenticated','automation.tenant_request_worker(text,jsonb)','execute') then raise exception 'FAIL consent worker exposed';end if;
 if has_table_privilege('authenticated','automation.sms_consents','select') or has_table_privilege('anon','automation.sms_disclosures','select') then raise exception 'FAIL audit data exposed';end if;
end $$;
select 'PASS: consent binding, freshness, STOP, request scope, idempotency and backend-only permissions; all fixtures rolled back' result;
