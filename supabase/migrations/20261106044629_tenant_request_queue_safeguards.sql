create or replace function automation.tenant_request_worker(operation text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare req automation.tenant_requests;s automation.operational_snapshots;n automation.notification_outbox;cfg automation.settings;
 f public.facilities;result jsonb;eid uuid;cid uuid;a public.assignments;l public.locks;row jsonb;begin
 select * into cfg from automation.settings where id;
 if operation='tenant_directory' then
  return jsonb_build_object('liveApproved',cfg.mode='live' and cfg.acceptance_passed and cfg.live_approved_at is not null and cfg.tenant_requests_approved_at is not null,
   'facilities',coalesce((select jsonb_agg(jsonb_build_object('id',left(encode(extensions.digest(directory_fac.id::text,'sha256'),'hex'),24),'name',directory_fac.name,'address',directory_fac.address,'phone',case when c.verified_at>now()-interval '7 days' then c.phone else null end) order by directory_fac.name) from public.facilities directory_fac left join automation.tenant_facility_contacts c on c.facility_id=directory_fac.id where directory_fac.active),'[]'));
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
  if req.notification_id is not null then select * into n from automation.notification_outbox where id=req.notification_id;update automation.tenant_requests set state=case n.state when 'pending' then 'pending_delivery' when 'dispatching' then 'pending_delivery' else n.state end where id=req.id;return jsonb_build_object('id',n.id,'state',n.state);end if;
  perform pg_advisory_xact_lock(hashtextextended('notification-lease:'||req.lease_id,0));
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

-- Serialize automatic and tenant notices for the same lease before checking an unresolved dispatch.
do $$declare definition text;needle text:='n.id:=gen_random_uuid();n.initiator:=''automatic'';';begin
 definition:=pg_get_functiondef('automation.worker(text,text,jsonb)'::regprocedure);
 if position(needle in definition)=0 then raise exception 'Automatic enqueue integration point changed';end if;
 definition:=replace(definition,needle,'perform pg_advisory_xact_lock(hashtextextended(''notification-lease:''||s.lease_id,0));if exists(select 1 from automation.notification_outbox where lease_id=s.lease_id and state in (''pending'',''dispatching'',''unknown'',''submitted'')) then return null;end if;'||needle);
 execute definition;
end $$;
