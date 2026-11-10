-- One isolated fixture, no inventory/tenant writes and no general SMS activation.
create table automation.controlled_sms_test (
 id uuid primary key check(id='294f24bd-2e55-46d8-bcd6-354faa418d5b'),
 phone_hash text not null check(phone_hash='daecc6a756afc5e3afb72983a2f23862de66afc377bf959f162e651edb0c2694'),
 body_hash text not null check(body_hash='01e6ae8cc7462d7ab47cf006d9e8e9c630ec7ed1c55f43fb9c6cd8472e4586b8'),
 encrypted_payload bytea not null,fixture_version int not null default 1 check(fixture_version=1),
 consent_scope text not null default 'single_controlled_test' check(consent_scope='single_controlled_test'),
 recipient_authorized_at timestamptz not null,authorization_source text not null,
 send_approved_at timestamptz,approval_expires_at timestamptz,
 state text not null default 'prepared' check(state in ('prepared','dispatching','submitted','delivered','failed','unknown')),
 attempt_id uuid unique,provider_sid text unique,delivery_status text,error_code text,
 reserved_at timestamptz,submitted_at timestamptz,delivered_at timestamptz,
 audit jsonb not null default '[]',created_at timestamptz not null default now(),
 constraint bounded_test_approval check((send_approved_at is null and approval_expires_at is null) or
  (send_approved_at is not null and approval_expires_at>send_approved_at and approval_expires_at<=send_approved_at+interval '15 minutes'))
);
alter table automation.controlled_sms_test enable row level security;
revoke all on automation.controlled_sms_test from public,anon,authenticated;

create function automation.controlled_sms_worker(operation text,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t automation.controlled_sms_test;cfg automation.settings;payload jsonb;incoming text;new_state text;begin
 select * into t from automation.controlled_sms_test where id='294f24bd-2e55-46d8-bcd6-354faa418d5b' for update;
 if not found then return jsonb_build_object('state','fixture_missing','approved',false,'prepared',false);end if;
 select * into cfg from automation.settings where id;
 if operation='controlled_sms_inspect' then
  return jsonb_build_object('state',t.state,'prepared',true,'recipient','***-***-0224','recipientRestricted',true,
   'fixtureOnly',true,'scope',t.consent_scope,'remainingSubmissions',case when t.state='prepared' then 1 else 0 end,
   'suppressed',exists(select 1 from automation.sms_suppressions where phone_hash=t.phone_hash),
   'approved',coalesce(t.state='prepared' and t.send_approved_at<=now() and t.approval_expires_at>now(),false),
   'generalMode',cfg.mode,'submitted',t.submitted_at is not null);
 elsif operation='controlled_sms_claim' then
  if cfg.mode<>'dry_run' or cfg.live_approved_at is not null or cfg.tenant_requests_approved_at is not null
   or t.state<>'prepared' or t.attempt_id is not null or t.send_approved_at is null or t.send_approved_at>now()
   or t.approval_expires_at is null or t.approval_expires_at<=now()
   or exists(select 1 from automation.sms_suppressions where phone_hash=t.phone_hash) then return null;end if;
  payload:=extensions.pgp_sym_decrypt(t.encrypted_payload,(select value from private.encryption_key))::jsonb;
  if payload->>'fixtureId' is distinct from t.id::text or payload->>'phone' is distinct from '+18032460224'
   or (payload->>'fixtureVersion')::int is distinct from t.fixture_version or payload->>'scope' is distinct from t.consent_scope
   or encode(extensions.digest(payload->>'phone','sha256'),'hex') is distinct from t.phone_hash
   or encode(extensions.digest(payload->>'body','sha256'),'hex') is distinct from t.body_hash then return null;end if;
  update automation.controlled_sms_test set state='dispatching',attempt_id=gen_random_uuid(),reserved_at=now(),
   audit=audit||jsonb_build_array(jsonb_build_object('action','reserved','at',now())) where id=t.id returning * into t;
  return payload||jsonb_build_object('phoneHash',t.phone_hash,'bodyHash',t.body_hash,'attemptId',t.attempt_id,
   'reserved',true,'suppressed',false,'suppressionCheckedAt',now(),'sendApprovedAt',t.send_approved_at,'approvalExpiresAt',t.approval_expires_at);
 elsif operation='controlled_sms_result' then
  if t.attempt_id is null or t.attempt_id is distinct from (p->>'attemptId')::uuid then return null;end if;
  if t.provider_sid is not null and p->>'providerSid' is not null and t.provider_sid<>p->>'providerSid' then return null;end if;
  incoming:=p->>'state';if incoming not in ('accepted','queued','sending','sent','delivered','undelivered','failed','unknown') then return null;end if;
  if incoming in ('accepted','queued','sending','sent','delivered','undelivered') and nullif(p->>'providerSid','') is null then return null;end if;
  new_state:=case when t.state='delivered' or incoming='delivered' then 'delivered'
   when t.state='failed' then 'failed' when incoming in ('failed','undelivered') then 'failed'
   when incoming='unknown' and t.provider_sid is null then 'unknown' else 'submitted' end;
  update automation.controlled_sms_test set state=new_state,provider_sid=coalesce(provider_sid,nullif(p->>'providerSid','')),
   delivery_status=case when state='delivered' then delivery_status when new_state='delivered' then 'delivered' else incoming end,
   error_code=case when p->>'errorCode' ~ '^[0-9]{1,8}$' or p->>'errorCode' in ('provider_outcome_unknown','controlled_test_dispatch_blocked','provider_rejected') then p->>'errorCode' else null end,
   submitted_at=case when nullif(p->>'providerSid','') is not null then coalesce(submitted_at,now()) else submitted_at end,
   delivered_at=case when new_state='delivered' then coalesce(delivered_at,now()) else delivered_at end,
   audit=audit||jsonb_build_array(jsonb_build_object('action','provider_result','state',incoming,'at',now())) where id=t.id;
  return jsonb_build_object('ok',true);
 end if;return null;
end $$;
revoke all on function automation.controlled_sms_worker(text,jsonb) from public,anon,authenticated;
-- Existing authenticated worker transport and signed delivery callback are reused.
do $$declare definition text;needle text;begin
 definition:=pg_get_functiondef('automation.worker(text,text,jsonb)'::regprocedure);
 needle:='if left(operation,7)=''tenant_''';
 if position(needle in definition)=0 then raise exception 'Controlled worker integration point changed';end if;
 execute replace(definition,needle,'if left(operation,15)=''controlled_sms_'' then return automation.controlled_sms_worker(operation,p);elsif left(operation,7)=''tenant_''');
end $$;
