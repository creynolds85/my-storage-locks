-- Request-only affirmative consent extends the existing private receipt and SMS outbox.
-- No enrollment in automatic messages, suppression changes, live activation, or inventory writes.
create table automation.sms_disclosures (
 version text primary key, body text not null, proof_url text not null,
 scope text not null check(scope='request'), recorded_at timestamptz not null default now()
);
alter table automation.sms_disclosures enable row level security;
revoke all on automation.sms_disclosures from public,anon,authenticated;
insert into automation.sms_disclosures(version,body,proof_url,scope) values(
 '2026-11-08-request-1',
 'I agree to receive one transactional text from My Storage Locks, operated by Storage Operations Specialists LLC on behalf of my selected facility, for this request. The message may contain a lock combination and access or lock-return instructions. One message per verified request. Message and data rates may apply. Reply STOP to opt out or HELP for help. Consent is optional and is not a condition of renting. This does not enroll me in recurring messages.',
 'https://mystoragelocks.com/get-combination','request');
alter table automation.tenant_requests
 add column sms_consent boolean not null default false,
 add column consent_version text references automation.sms_disclosures(version),
 add column consent_asserted_at timestamptz,
 add column consent_verified_at timestamptz,
 add constraint tenant_consent_assertion check((sms_consent and consent_version is not null and consent_asserted_at is not null) or (not sms_consent and consent_version is null and consent_asserted_at is null));
alter table automation.sms_consents alter column recorded_by drop not null;
alter table automation.sms_consents
 add column scope text not null default 'program',
 add column tenant_request_id uuid unique references automation.tenant_requests,
 add constraint consent_provenance check(
  (scope='program' and tenant_request_id is null and recorded_by is not null)
  or (scope='request' and tenant_request_id is not null and recorded_by is null and proof_source='verified_tenant_request'));

-- Preserve every existing operation; wrapper adds intake evidence and source-bound verification.
alter function automation.tenant_request_worker(text,jsonb) rename to tenant_request_worker_before_consent;
create function automation.tenant_request_worker(operation text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; req automation.tenant_requests;s automation.operational_snapshots;cid uuid;begin
 if operation='tenant_consent_verify' then
  select * into req from automation.tenant_requests where id=(p->>'id')::uuid for update;
  if not found or req.sms_consent is not true or req.consent_version<>'2026-11-08-request-1'
   or req.expires_at<=now() or req.state not in ('pending','verified','dry_run','pending_delivery') then return null;end if;
  select * into s from automation.operational_snapshots where lease_id=p->>'leaseId';
  if not found or req.phone_digest is distinct from s.phone_hash or s.suppressed is distinct from false
   or s.observed_at<now()-interval '120 seconds' or s.observed_at>now()+interval '5 seconds'
   or (s.facts->>'verified')::boolean is distinct from true
   or (s.facts->>'verifiedAt')::timestamptz<now()-interval '120 seconds'
   or (s.facts->>'verifiedAt') is null or (s.facts->>'verifiedAt')::timestamptz>now()+interval '5 seconds'
   or (s.facts->>'active')::boolean is distinct from true
   or (s.facts->>'paymentClear')::boolean is distinct from true
   or (s.facts->>'auctionClear')::boolean is distinct from true
   or (s.facts->>'restrictionsClear')::boolean is distinct from true
   or (s.facts->>'overlockNeeded')::boolean is distinct from false
   or lower(trim(s.unit_label)) is distinct from lower(trim(extensions.pgp_sym_decrypt(req.unit_encrypted,(select value from private.encryption_key))))
   or not exists(select 1 from automation.facility_links f where f.facility_id=req.facility_id and f.source_org_id=s.source_org_id and f.source_facility_id=s.source_facility_id)
   or exists(select 1 from automation.sms_suppressions z where z.phone_hash=req.phone_digest) then return null;end if;
  -- Recheck unambiguous eligible physical assignment; consent never creates an assignment.
  if (select count(*) from public.assignments a where a.facility_id=req.facility_id and lower(trim(a.unit))=lower(trim(s.unit_label)) and a.released_at is null)<>1
   or not exists(select 1 from public.assignments a join public.locks l on l.id=a.lock_id join automation.assignment_links al on al.assignment_id=a.id
     where a.facility_id=req.facility_id and a.released_at is null and lower(trim(a.unit))=lower(trim(s.unit_label))
     and al.source_org_id=s.source_org_id and al.source_unit_id=s.source_unit_id and l.status=a.type
     and ((a.type='vacant' and (s.facts->>'rentalAccessReady')::boolean is true and (s.facts->>'requirementsSatisfied')::boolean is true and (s.facts->>'moveInAllowed')::boolean is true)
       or (a.type='overlock' and (s.facts->>'releaseAccessReady')::boolean is true))) then return null;end if;
  insert into automation.sms_consents(facility_id,customer_id,phone_hash,purpose,proof_source,proof_version,granted_at,recorded_by,scope,tenant_request_id)
   values(req.facility_id,s.customer_id,s.phone_hash,'lock_access','verified_tenant_request',req.consent_version,req.consent_asserted_at,null,'request',req.id)
   on conflict(tenant_request_id) do nothing;
  select id into cid from automation.sms_consents where tenant_request_id=req.id and facility_id=req.facility_id and customer_id=s.customer_id and phone_hash=s.phone_hash and scope='request' and revoked_at is null;
  if cid is null then return null;end if;
  update automation.tenant_requests set consent_verified_at=now() where id=req.id;
  return jsonb_build_object('verified',true,'proofId',cid);
 end if;
 result:=automation.tenant_request_worker_before_consent(operation,p);
 if operation='tenant_intake' and result->>'requestId' is not null then
  if p->'smsConsent'='true'::jsonb and p->>'consentVersion'='2026-11-08-request-1' then
   update automation.tenant_requests set sms_consent=true,consent_version='2026-11-08-request-1',consent_asserted_at=created_at where id=(result->>'requestId')::uuid;
  end if;
 elsif operation='tenant_get' and result is not null then
  select * into req from automation.tenant_requests where id=(p->>'id')::uuid;
  result:=result||jsonb_build_object('smsConsent',req.sms_consent);
 end if;
 return result;
end $$;
revoke all on function automation.tenant_request_worker(text,jsonb),automation.tenant_request_worker_before_consent(text,jsonb) from public,anon,authenticated;

-- Request receipts can authorize exactly their own notification, never automatic events.
do $$declare definition text;needle text;begin
 definition:=pg_get_functiondef('automation.worker(text,text,jsonb)'::regprocedure);
 needle:='select id into cid from automation.sms_consents where facility_id=f and customer_id=s.customer_id and phone_hash=s.phone_hash and revoked_at is null order by granted_at desc limit 1;';
 if position(needle in definition)=0 then raise exception 'Consent context integration point changed';end if;
 definition:=replace(definition,needle,'select id into cid from automation.sms_consents where facility_id=f and customer_id=s.customer_id and phone_hash=s.phone_hash and revoked_at is null and (scope=''program'' or (scope=''request'' and tenant_request_id=(p->>''requestId'')::uuid)) order by granted_at desc limit 1;');
 execute definition;
 definition:=pg_get_functiondef('automation.is_current(automation.notification_outbox)'::regprocedure);
 needle:='and c.facility_id=n.facility_id';
 if position(needle in definition)=0 then raise exception 'Dispatch consent integration point changed';end if;
 execute replace(definition,needle,'and (c.scope=''program'' or (c.scope=''request'' and n.initiator=''tenant_request'' and c.tenant_request_id=n.tenant_request_id)) and c.facility_id=n.facility_id');
end $$;
