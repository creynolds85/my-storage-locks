-- Public requests use the existing authenticated worker, inbox, outbox and sender.
-- No live SMS settings, physical locks, combinations or assignments are changed.
alter table automation.settings add column tenant_requests_approved_at timestamptz;
create table automation.tenant_requests(
 id uuid primary key default gen_random_uuid(),facility_id uuid not null references public.facilities,
 unit_encrypted bytea not null,unit_hash text not null,phone_digest text not null,phone_rate_hash text not null,ip_hash text not null,
 dedupe_key text not null unique,nonce_hash text not null unique,created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '15 minutes',
 state text not null default 'pending' check(state in ('pending','verified','blocked','dry_run','pending_delivery','submitted','delivered','failed','unknown','cancelled')),
 reason text,verified_at timestamptz,lease_id text,source_unit_id text,customer_id text,snapshot_version bigint,
 assignment_id uuid references public.assignments,lock_id uuid references public.locks,lock_version int,notification_id uuid
);
create index tenant_request_ip_time on automation.tenant_requests(ip_hash,created_at desc);
create index tenant_request_phone_time on automation.tenant_requests(phone_rate_hash,created_at desc);
create index tenant_request_unit_time on automation.tenant_requests(unit_hash,created_at desc);
create table automation.tenant_facility_contacts(facility_id uuid primary key references public.facilities,phone text,verified_at timestamptz not null default now());
alter table automation.tenant_requests enable row level security;
alter table automation.tenant_facility_contacts enable row level security;
revoke all on automation.tenant_requests,automation.tenant_facility_contacts from public,anon,authenticated;
alter table automation.notification_outbox add column initiator text not null default 'automatic' check(initiator in ('automatic','tenant_request')),add column tenant_request_id uuid references automation.tenant_requests;
alter table automation.tenant_requests add constraint tenant_request_notification foreign key(notification_id) references automation.notification_outbox;

create function automation.recovery_task(n automation.notification_outbox) returns void language plpgsql security definer set search_path='' as $$
declare typ text:=case n.kind when 'overlock_clearance' then 'overlock_removal' else 'vacant_recovery' end;begin
 perform 1 from public.assignments where id=n.assignment_id for update;
 update public.action_items set notification_id=n.id,notification_state=n.state,updated_at=now() where assignment_id=n.assignment_id and kind=typ and state='open';
 if not found then perform automation.task('recovery-assignment:'||n.assignment_id::text,n.facility_id,typ,case n.kind when 'overlock_clearance' then 'Overlock removal required' else 'Vacant lock recovery after rental' end,'Access eligibility confirmed. Confirm physical lock recovery before returning it to inventory.',n.assignment_id,n.id,'confirmed',n.state);end if;
end $$;
revoke all on function automation.recovery_task(automation.notification_outbox) from public,anon,authenticated;

-- This function is reachable only after automation.worker validates its existing server credential.
create function automation.tenant_request_worker(operation text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare req automation.tenant_requests;s automation.operational_snapshots;n automation.notification_outbox;cfg automation.settings;
 f public.facilities;result jsonb;eid uuid;cid uuid;a public.assignments;l public.locks;row jsonb;begin
 select * into cfg from automation.settings where id;
 if operation='tenant_directory' then
  return jsonb_build_object('liveApproved',cfg.mode='live' and cfg.acceptance_passed and cfg.live_approved_at is not null and cfg.tenant_requests_approved_at is not null,
   'facilities',coalesce((select jsonb_agg(jsonb_build_object('id',left(encode(extensions.digest(f.id::text,'sha256'),'hex'),24),'name',f.name,'address',f.address,'phone',case when c.verified_at>now()-interval '7 days' then c.phone else null end) order by f.name) from public.facilities f left join automation.tenant_facility_contacts c on c.facility_id=f.id where f.active),'[]'));
 elsif operation='tenant_directory_needed' then
  return to_jsonb(not exists(select 1 from automation.tenant_facility_contacts where verified_at>now()-interval '24 hours'));
 elsif operation='tenant_directory_save' then
  if jsonb_array_length(p->'contacts')>200 then return null;end if;
  for row in select value from jsonb_array_elements(p->'contacts') loop
   select * into f from public.facilities where source_org_id=p->>'orgId' and source_facility_id=row->>'sourceFacilityId';
   if found and (row->>'phone' is null or row->>'phone' ~ '^\+[1-9][0-9]{7,14}$') then
    insert into automation.tenant_facility_contacts values(f.id,row->>'phone',now()) on conflict(facility_id) do update set phone=excluded.phone,verified_at=excluded.verified_at;
   end if;
  end loop;return jsonb_build_object('ok',true);
 elsif operation='tenant_intake' then
  if pg_column_size(p)>3000 or p->>'phoneDigest' !~ '^[a-f0-9]{64}$' or p->>'phoneRateHash' !~ '^[a-f0-9]{64}$' or p->>'ipHash' !~ '^[a-f0-9]{64}$' or p->>'unitHash' !~ '^[a-f0-9]{64}$' or p->>'dedupeKey' !~ '^[a-f0-9]{64}$' or p->>'nonceHash' !~ '^[a-f0-9]{64}$' or length(p->>'unit') not between 1 and 60 then return null;end if;
  -- One short transaction makes limits consistent across server instances and retries.
  perform pg_advisory_xact_lock(hashtextextended('my-storage-locks-tenant-intake',0));
  if exists(select 1 from automation.tenant_requests where dedupe_key=p->>'dedupeKey' or nonce_hash=p->>'nonceHash') then return null;end if;
  if (select count(*) from automation.tenant_requests where created_at>now()-interval '1 minute')>=40
   or (select count(*) from automation.tenant_requests where ip_hash=p->>'ipHash' and created_at>now()-interval '15 minutes')>=6
   or (select count(*) from automation.tenant_requests where ip_hash=p->>'ipHash' and created_at>now()-interval '1 day')>=24
   or (select count(*) from automation.tenant_requests where phone_rate_hash=p->>'phoneRateHash' and created_at>now()-interval '30 minutes')>=3
   or (select count(*) from automation.tenant_requests where unit_hash=p->>'unitHash' and created_at>now()-interval '30 minutes')>=3
   or exists(select 1 from automation.tenant_requests where unit_hash=p->>'unitHash' and phone_rate_hash=p->>'phoneRateHash' and created_at>now()-interval '10 minutes') then return null;end if;
  select * into f from public.facilities where active and left(encode(extensions.digest(id::text,'sha256'),'hex'),24)=p->>'facility';
  if not found then return null;end if;
  insert into automation.tenant_requests(facility_id,unit_encrypted,unit_hash,phone_digest,phone_rate_hash,ip_hash,dedupe_key,nonce_hash)
  values(f.id,extensions.pgp_sym_encrypt(p->>'unit',(select value from private.encryption_key)),p->>'unitHash',p->>'phoneDigest',p->>'phoneRateHash',p->>'ipHash',p->>'dedupeKey',p->>'nonceHash') returning * into req;
  insert into automation.event_inbox(dedupe_key,event_type,reference,occurred_at) values('tenant-request:'||req.id::text,'tenant_request',jsonb_build_object('requestId',req.id),req.created_at) returning id into eid;
  return jsonb_build_object('requestId',req.id,'eventId',eid);
 elsif operation='tenant_get' then
  select * into req from automation.tenant_requests where id=(p->>'id')::uuid;
  if not found or req.state not in ('pending','verified','pending_delivery','dry_run') then return null;end if;
  select * into f from public.facilities where id=req.facility_id and active;
  if not found then return null;end if;
  return jsonb_build_object('id',req.id,'facilityId',f.id,'sourceOrgId',f.source_org_id,'sourceFacilityId',f.source_facility_id,'unit',extensions.pgp_sym_decrypt(req.unit_encrypted,(select value from private.encryption_key)),'unitHash',req.unit_hash,'phoneDigest',req.phone_digest,'expiresAt',req.expires_at);
 elsif operation='tenant_finish' then
  update automation.tenant_requests set state='blocked',reason=left(p->>'reason',80) where id=(p->>'id')::uuid and state in ('pending','verified','pending_delivery','dry_run');
  return jsonb_build_object('ok',true);
 elsif operation='tenant_verify' then
  select * into req from automation.tenant_requests where id=(p->>'id')::uuid for update;
  if not found or req.expires_at<=now() or req.state not in ('pending','verified','dry_run','pending_delivery') then return null;end if;
  select * into s from automation.operational_snapshots where lease_id=p->>'leaseId';
  if not found or req.phone_digest is distinct from s.phone_hash or lower(trim(s.unit_label)) is distinct from lower(trim(extensions.pgp_sym_decrypt(req.unit_encrypted,(select value from private.encryption_key))))
   or not exists(select 1 from automation.facility_links where facility_id=req.facility_id and source_org_id=s.source_org_id and source_facility_id=s.source_facility_id)
   or s.observed_at<now()-interval '120 seconds' or s.suppressed is distinct from false then return jsonb_build_object('verified',false,'reason','eligibility_unverified');end if;
  select * into a from public.assignments where id=(p->>'assignmentId')::uuid and released_at is null;
  select * into l from public.locks where id=a.lock_id;
  if not found or a.facility_id<>req.facility_id or a.unit is distinct from s.unit_label or l.version<>(p->>'lockVersion')::int or l.id<>(p->>'lockId')::uuid or l.status<>a.type or a.type not in ('vacant','overlock')
   or (select count(*) from public.assignments where facility_id=req.facility_id and lower(unit)=lower(a.unit) and released_at is null)<>1
   or not exists(select 1 from automation.assignment_links where assignment_id=a.id and source_org_id=s.source_org_id and source_unit_id=s.source_unit_id) then return jsonb_build_object('verified',false,'reason','assignment_changed');end if;
  update automation.tenant_requests set state=case when state='pending_delivery' then state else 'verified' end,verified_at=now(),lease_id=s.lease_id,source_unit_id=s.source_unit_id,customer_id=s.customer_id,snapshot_version=s.version,assignment_id=a.id,lock_id=l.id,lock_version=l.version,reason=null where id=req.id;
  return jsonb_build_object('verified',true);
 elsif operation='tenant_enqueue' then
  select * into req from automation.tenant_requests where id=(p->>'id')::uuid for update;
  if not found or req.state<>'verified' or req.expires_at<=now() or req.verified_at<now()-interval '120 seconds' then return null;end if;
  select * into s from automation.operational_snapshots where lease_id=req.lease_id;
  if exists(select 1 from automation.notification_outbox where lease_id=req.lease_id and state in ('pending','dispatching','unknown','submitted')) then
   update automation.tenant_requests set state='blocked',reason='previous_delivery_unresolved' where id=req.id;
   perform automation.task('tenant-delivery:'||req.lease_id,req.facility_id,'sms_failure','Tenant notification needs review','Check the previous notification before sending another message.',req.assignment_id);return null;
  end if;
  select id into cid from automation.sms_consents where id=(p->>'consentId')::uuid and facility_id=req.facility_id and customer_id=req.customer_id and phone_hash=req.phone_digest and revoked_at is null;
  if cid is null then return null;end if;
  n.id:=gen_random_uuid();n.dedupe_key:='tenant-request:'||req.id::text;n.kind:=case (select type from public.assignments where id=req.assignment_id) when 'overlock' then 'overlock_clearance' else 'new_rental' end;
  n.facility_id:=req.facility_id;n.lease_id:=req.lease_id;n.customer_id:=req.customer_id;n.source_unit_id:=req.source_unit_id;n.assignment_id:=req.assignment_id;n.lock_id:=req.lock_id;n.lock_version:=req.lock_version;n.phone_hash:=req.phone_digest;n.consent_id:=cid;n.episode_id:='tenant-request:'||req.id::text;n.template_version:=p->>'templateVersion';n.source_occurred_at:=req.created_at;n.initiator:='tenant_request';n.tenant_request_id:=req.id;n.created_at:=now();
  if not automation.is_current(n) then return null;end if;
  n.state:=case when cfg.mode='live' and cfg.acceptance_passed and cfg.live_approved_at is not null and cfg.activation_at is not null and cfg.tenant_requests_approved_at is not null and req.created_at>=greatest(cfg.activation_at,cfg.tenant_requests_approved_at) and cfg.policy_version=n.template_version then 'pending' else 'dry_run' end;
  insert into automation.notification_outbox select (n).* on conflict(dedupe_key) do nothing;
  update automation.tenant_requests set state=case n.state when 'pending' then 'pending_delivery' else 'dry_run' end,notification_id=n.id where id=req.id;
  perform automation.recovery_task(n);
  insert into automation.notification_attempts(notification_id,event_key,state) values(n.id,'tenant-created:'||n.id::text,n.state);
  return jsonb_build_object('id',n.id,'state',n.state);
 end if;raise exception 'Invalid tenant request operation';
end $$;
revoke all on function automation.tenant_request_worker(text,jsonb) from public,anon,authenticated;

create or replace function automation.is_current(n automation.notification_outbox) returns boolean language sql security definer set search_path='' as $$
select exists(
 select 1 from public.assignments a join public.locks l on l.id=a.lock_id
 join automation.assignment_links al on al.assignment_id=a.id
 join automation.operational_snapshots s on s.lease_id=n.lease_id
 join automation.sms_consents c on c.id=n.consent_id
 where a.id=n.assignment_id and a.lock_id=n.lock_id and a.facility_id=n.facility_id and a.released_at is null
 and a.type=case n.kind when 'overlock_clearance' then 'overlock' else 'vacant' end and l.status=a.type and l.version=n.lock_version
 and al.source_unit_id=n.source_unit_id and al.source_org_id=s.source_org_id and s.source_unit_id=n.source_unit_id
 and s.customer_id=n.customer_id and s.phone_hash=n.phone_hash and s.suppressed is false
 and ((n.initiator='automatic' and (s.facts->>'episodeId')=n.episode_id and a.assigned_at<=n.source_occurred_at)
 or (n.initiator='tenant_request' and exists(select 1 from automation.tenant_requests r where r.id=n.tenant_request_id and r.state in ('verified','dry_run','pending_delivery') and r.lease_id=s.lease_id and r.customer_id=s.customer_id and r.source_unit_id=s.source_unit_id and r.facility_id=n.facility_id and r.assignment_id=a.id and r.lock_id=l.id and r.lock_version=l.version and r.phone_digest=s.phone_hash and r.snapshot_version=s.version and r.expires_at>now() and r.verified_at>now()-interval '120 seconds')))
 and (s.facts->>'verifiedAt')::timestamptz>now()-interval '120 seconds' and (s.facts->>'verifiedAt')::timestamptz<=now()+interval '5 seconds'
 and (select count(*) from public.assignments ax where ax.facility_id=a.facility_id and lower(ax.unit)=lower(a.unit) and ax.released_at is null)=1
 and s.observed_at>now()-interval '120 seconds' and (s.facts->>'verified')::boolean is true
 and (s.facts->>'active')::boolean is true and (s.facts->>'paymentClear')::boolean is true
 and (s.facts->>'auctionClear')::boolean is true and (s.facts->>'restrictionsClear')::boolean is true
 and (s.facts->>'overlockNeeded')::boolean is false
 and ((n.kind='overlock_clearance' and case n.initiator when 'tenant_request' then (s.facts->>'releaseAccessReady')::boolean else (s.facts->>'clearanceTransition')::boolean end is true)
 or (n.kind='new_rental' and case n.initiator when 'tenant_request' then (s.facts->>'rentalAccessReady')::boolean else (s.facts->>'rentalCompleted')::boolean end is true and (s.facts->>'requirementsSatisfied')::boolean is true and (s.facts->>'moveInAllowed')::boolean is true))
 and c.facility_id=n.facility_id and c.customer_id=n.customer_id and c.phone_hash=n.phone_hash and c.revoked_at is null
 and not exists(select 1 from automation.sms_suppressions z where z.phone_hash=n.phone_hash)
 and (select count(*) from public.assignments ax join automation.assignment_links x on x.assignment_id=ax.id where ax.facility_id=n.facility_id and ax.released_at is null and x.source_org_id=s.source_org_id and x.source_unit_id=n.source_unit_id)=1
);
$$;

-- Extend the same durable transport. Public clients never receive the worker token.
do $$declare definition text;old_recovery text;begin
 definition:=pg_get_functiondef('automation.worker(text,text,jsonb)'::regprocedure);
 if position('if operation in (''warehouse_claim''' in definition)=0 then raise exception 'Worker integration point changed';end if;
 definition:=replace(definition,'if operation in (''warehouse_claim''','if left(operation,7)=''tenant_'' then return automation.tenant_request_worker(operation,p);elsif operation in (''warehouse_claim''');
 definition:=replace(definition,'n.id:=gen_random_uuid();n.dedupe_key:=p->>''key'';','n.id:=gen_random_uuid();n.initiator:=''automatic'';n.dedupe_key:=p->>''key'';');
 definition:=replace(definition,'''customerId'',s.customer_id) from automation.notification_outbox n','''customerId'',s.customer_id,''initiator'',n.initiator,''tenantRequestId'',n.tenant_request_id) from automation.notification_outbox n');
 definition:=replace(definition,'where ((state in (''pending'',''retry'')','where (coalesce((p->>''tenantOnly'')::boolean,false)=false or event_type=''tenant_request'') and ((state in (''pending'',''retry'')');
 definition:=replace(definition,'order by received_at for update skip locked','order by case when event_type=''tenant_request'' then 1 else 0 end,received_at for update skip locked');
 old_recovery:=$replace$perform automation.task('recovery:'||n.dedupe_key,f,case n.kind when 'overlock_clearance' then 'overlock_removal' else 'vacant_recovery' end,case n.kind when 'overlock_clearance' then 'Overlock removal required' else 'Vacant lock recovery after rental' end,'Access eligibility confirmed. Physical lock remains assigned until recovery is confirmed.',n.assignment_id,outid,'confirmed',n.state);$replace$;
 if position(old_recovery in definition)=0 then raise exception 'Recovery integration point changed';end if;
 definition:=replace(definition,old_recovery,'perform automation.recovery_task(n);');
 -- Revoking self-service approval cancels rather than dispatches previously queued requests.
 definition:=replace(definition,'if not automation.is_current(n) then update automation.notification_outbox set state=''cancelled''', 'if (n.initiator=''tenant_request'' and (cfg.tenant_requests_approved_at is null or n.source_occurred_at<cfg.tenant_requests_approved_at)) or not automation.is_current(n) then update automation.notification_outbox set state=''cancelled''');
 -- Backend request status follows the same provider callbacks as automatic notices.
 definition:=replace(definition,'insert into automation.notification_attempts(notification_id,event_key,state,provider_sid,error_code) values(n.id,', 'update automation.tenant_requests set state=case when incoming=''delivered'' then ''delivered'' when incoming in (''failed'',''undelivered'') then ''failed'' when incoming=''unknown'' then ''unknown'' else ''submitted'' end where id=n.tenant_request_id;insert into automation.notification_attempts(notification_id,event_key,state,provider_sid,error_code) values(n.id,');
 execute definition;
end $$;
