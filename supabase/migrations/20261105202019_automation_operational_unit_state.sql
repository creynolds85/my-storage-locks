-- Store unit availability/reservation/occupancy observations independently from physical lock inventory.
alter table automation.unit_links add column operational_state jsonb not null default '{}';
create or replace function automation.worker(token text,operation text,p jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare cfg automation.settings; s automation.operational_snapshots; n automation.notification_outbox;
 e automation.event_inbox; f uuid; aid uuid; outid uuid; cid uuid; ph text; result jsonb; item jsonb; incoming text; ownerid uuid;
begin
select * into cfg from automation.settings where id;
if length(coalesce(token,''))<32 or cfg.worker_token_hash is null or encode(extensions.digest(token,'sha256'),'hex')<>cfg.worker_token_hash then raise exception 'Worker authentication required' using errcode='42501';end if;
if pg_column_size(p)>500000 then raise exception 'Payload too large';end if;
if operation='baseline_ready' then return to_jsonb(cfg.baseline_complete);
elsif operation='heartbeat' then
 update automation.settings set last_tick_at=now(),readiness=p,updated_at=now() where id;
 if coalesce((p->>'ready')::boolean,false) is false then perform automation.task('sync:configuration',null,'sync_failure','Cubby synchronization needs configuration','Operational API access or required server configuration is not ready.');end if;
 return jsonb_build_object('mode',cfg.mode,'baselineComplete',cfg.baseline_complete,'evaluationStartedAt',cfg.evaluation_started_at,'maxAgeSeconds',cfg.max_age_seconds);
elsif operation='sync_claim' then
 ownerid:=(p->>'owner')::uuid;
 update automation.settings set sync_owner=ownerid,sync_until=now()+interval '100 seconds' where id and (sync_until is null or sync_until<now());
 if not found then return null;end if;
 return jsonb_build_object('cursors',cfg.cursors,'baselineComplete',cfg.baseline_complete,'evaluationStartedAt',cfg.evaluation_started_at);
elsif operation='sync_finish' then
 if (p->>'ok')::boolean is true then
 update automation.settings set last_sync_at=now(),last_error_code=null,cursors=coalesce(p->'cursors',cursors),baseline_complete=true,sync_owner=null,sync_until=null,updated_at=now() where id and sync_owner=(p->>'owner')::uuid;
 if found then update public.action_items set state='resolved',resolved_at=now(),updated_at=now() where cause_key in ('sync:outage','sync:configuration') and state='open';end if;
 else
 update automation.settings set last_failure_at=now(),last_error_code=p->>'errorCode',sync_owner=null,sync_until=null,updated_at=now() where id and sync_owner=(p->>'owner')::uuid;
 perform automation.task('sync:outage',null,'sync_failure','Cubby synchronization failed','Operational data is not current. Automatic code disclosure is blocked until fresh verification succeeds.');
 end if;return jsonb_build_object('ok',true);
elsif operation='links' then
 return coalesce((select jsonb_agg(jsonb_build_object('orgId',source_org_id,'sourceFacilityId',source_facility_id,'facilityId',facility_id)) from automation.facility_links),'[]');
elsif operation='units_save' then
 for item in select value from jsonb_array_elements(p->'units') loop
 select facility_id into f from automation.facility_links where source_org_id=p->>'orgId' and source_facility_id=item->>'facilityId';
 if f is not null then insert into automation.unit_links(source_org_id,source_facility_id,source_unit_id,facility_id,label,operational_state)
 values(p->>'orgId',item->>'facilityId',item->>'unitId',f,item->>'name',coalesce(item->'operationalState','{}'::jsonb))
 on conflict(source_org_id,source_unit_id) do update set label=excluded.label,observed_at=now(),operational_state=excluded.operational_state
 where automation.unit_links.facility_id=excluded.facility_id and automation.unit_links.source_facility_id=excluded.source_facility_id;end if;
 end loop;return jsonb_build_object('ok',true);
elsif operation='references_for_customer' then
 return coalesce((select jsonb_agg(jsonb_build_object('leaseId',lease_id,'facilityId',source_facility_id,'unitId',source_unit_id,'customerId',customer_id)) from automation.operational_snapshots where customer_id=p->>'customerId' and source_org_id=p->>'orgId'),'[]');
elsif operation='outbox_peek' then
 return (select jsonb_build_object('id',n.id,'leaseId',s.lease_id,'facilityId',s.source_facility_id,'unitId',s.source_unit_id,'customerId',s.customer_id) from automation.notification_outbox n join automation.operational_snapshots s on s.lease_id=n.lease_id where n.state='pending' and (p->>'id' is null or n.id=(p->>'id')::uuid) order by n.created_at limit 1);
elsif operation='snapshot_get' then
 select * into s from automation.operational_snapshots where lease_id=p->>'leaseId';
 if not found then return null;end if;
 return jsonb_build_object('facts',s.facts,'version',s.version,'sourceVersion',s.source_version);
elsif operation='snapshot_save' then
 ph:=case when nullif(p->'recipient'->>'phone','') is not null then encode(extensions.digest(p->'recipient'->>'phone','sha256'),'hex') else null end;
 insert into automation.operational_snapshots(lease_id,source_org_id,source_facility_id,source_unit_id,customer_id,facts,source_version,phone_encrypted,phone_hash,suppressed,unit_label,facility_name)
 values(p->'facts'->>'leaseId',p->>'orgId',p->'facts'->>'facilityId',p->'facts'->>'unitId',p->'facts'->>'customerId',p->'facts',p->>'sourceVersion',
 case when ph is not null then extensions.pgp_sym_encrypt(p->'recipient'->>'phone',(select value from private.encryption_key)) end,ph,(p->'recipient'->>'suppressed')::boolean,p->>'unitLabel',p->>'facilityName')
 on conflict(lease_id) do update set facts=excluded.facts,source_version=excluded.source_version,version=automation.operational_snapshots.version+1,observed_at=now(),phone_encrypted=excluded.phone_encrypted,phone_hash=excluded.phone_hash,suppressed=excluded.suppressed,unit_label=excluded.unit_label,facility_name=excluded.facility_name
 where automation.operational_snapshots.source_org_id=excluded.source_org_id and automation.operational_snapshots.source_facility_id=excluded.source_facility_id and automation.operational_snapshots.source_unit_id=excluded.source_unit_id
 and (automation.operational_snapshots.source_version is null or excluded.source_version>=automation.operational_snapshots.source_version);
 return jsonb_build_object('ok',found);
elsif operation='context' then
 select * into s from automation.operational_snapshots where lease_id=p->>'leaseId';if not found then return null;end if;
 select facility_id into f from automation.facility_links where source_org_id=s.source_org_id and source_facility_id=s.source_facility_id;
 if f is null then return jsonb_build_object('assignments','[]'::jsonb,'consent',null);end if;
 -- Bootstrap an immutable assignment link only with an unambiguous, freshly verified unit-label mapping.
 if (select count(*) from automation.unit_links where facility_id=f and lower(label)=lower(s.unit_label) and observed_at>now()-interval '120 seconds')=1 then
 insert into automation.assignment_links(assignment_id,source_org_id,source_unit_id)
 select a.id,s.source_org_id,s.source_unit_id from public.assignments a where a.facility_id=f and a.released_at is null and a.unit=s.unit_label
 and exists(select 1 from automation.unit_links u where u.source_org_id=s.source_org_id and u.source_unit_id=s.source_unit_id and u.facility_id=f and u.label=s.unit_label)
 on conflict(assignment_id) do nothing;
 end if;
 select jsonb_agg(jsonb_build_object('id',a.id,'lockId',a.lock_id,'lockVersion',l.version,'lockStatus',l.status,'facilityId',s.source_facility_id,'unitId',al.source_unit_id,'type',a.type,'releasedAt',a.released_at,'assignedAt',a.assigned_at)) into result
 from public.assignments a join public.locks l on l.id=a.lock_id join automation.assignment_links al on al.assignment_id=a.id
 where a.facility_id=f and a.released_at is null and al.source_org_id=s.source_org_id and al.source_unit_id=s.source_unit_id;
 select id into cid from automation.sms_consents where facility_id=f and customer_id=s.customer_id and phone_hash=s.phone_hash and revoked_at is null order by granted_at desc limit 1;
 return jsonb_build_object('facilityId',f,'assignments',coalesce(result,'[]'),'consent',case when cid is null then null else jsonb_build_object('proofId',cid,'customerId',s.customer_id,'phone',extensions.pgp_sym_decrypt(s.phone_encrypted,(select value from private.encryption_key)),'purpose','lock_access','valid',true,'suppressed',exists(select 1 from automation.sms_suppressions where phone_hash=s.phone_hash)) end,
 'policy',jsonb_build_object('evaluationStartedAt',cfg.evaluation_started_at,'maxAgeSeconds',cfg.max_age_seconds));
elsif operation='exception' then
 select facility_id into f from automation.facility_links where source_org_id=p->>'orgId' and source_facility_id=p->>'facilityId';
 perform automation.task('event:'||(p->>'key'),f,case when p->>'reason'='missing_assignment' then 'missing_assignment' else 'assignment_conflict' end,'Automatic access notification needs attention',case p->>'reason' when 'missing_assignment' then 'No verified current physical lock assignment was found.' when 'consent_unverified' then 'Access-message consent has not been verified.' when 'recipient_unverified' then 'The authorized tenant phone could not be verified.' else 'The current assignment or access eligibility could not be verified. No combination was sent.' end);
 return jsonb_build_object('ok',true);
elsif operation='enqueue' then
 select * into s from automation.operational_snapshots where lease_id=p->>'leaseId';
 select facility_id into f from automation.facility_links where source_org_id=s.source_org_id and source_facility_id=s.source_facility_id;
 if not cfg.baseline_complete or s.lease_id is null or f is null or (s.facts->>'occurredAt')::timestamptz<cfg.evaluation_started_at then return null;end if;
 select id into cid from automation.sms_consents where id=(p->>'consentId')::uuid and facility_id=f and customer_id=s.customer_id and phone_hash=s.phone_hash and revoked_at is null;
 if cid is null then return null;end if;
 n.id:=gen_random_uuid();n.dedupe_key:=p->>'key';n.kind:=p->>'kind';n.facility_id:=f;n.lease_id:=s.lease_id;n.customer_id:=s.customer_id;n.source_unit_id:=s.source_unit_id;n.assignment_id:=(p->>'assignmentId')::uuid;n.lock_id:=(p->>'lockId')::uuid;n.lock_version:=(p->>'lockVersion')::int;n.phone_hash:=s.phone_hash;n.consent_id:=cid;n.episode_id:=p->>'episodeId';n.template_version:=p->>'templateVersion';n.source_occurred_at:=(s.facts->>'occurredAt')::timestamptz;
 if not automation.is_current(n) then return null;end if;
 n.created_at:=now();n.state:=case when cfg.mode='live' and cfg.acceptance_passed and cfg.live_approved_at is not null and cfg.activation_at is not null and n.source_occurred_at>=cfg.activation_at and cfg.policy_version=n.template_version then 'pending' else 'dry_run' end;
 insert into automation.notification_outbox select (n).* on conflict(dedupe_key) do nothing returning id into outid;
 if outid is not null then
 perform automation.task('recovery:'||n.dedupe_key,f,case n.kind when 'overlock_clearance' then 'overlock_removal' else 'vacant_recovery' end,case n.kind when 'overlock_clearance' then 'Overlock removal required' else 'Vacant lock recovery after rental' end,'Access eligibility confirmed. Physical lock remains assigned until recovery is confirmed.',n.assignment_id,outid,'confirmed',n.state);
 insert into automation.notification_attempts(notification_id,event_key,state) values(outid,'created:'||outid::text,n.state);
 end if;return jsonb_build_object('id',outid,'state',n.state);
elsif operation='inbox_accept' then
 if p->>'eventType' not in ('move_in','overlock_clearance','lease_changed','document_completed','auction_changed') then return null;end if;
 insert into automation.event_inbox(dedupe_key,event_type,reference,occurred_at) values(p->>'key',p->>'eventType',p->'reference',(p->>'occurredAt')::timestamptz) on conflict(dedupe_key) do nothing returning id into outid;
 return jsonb_build_object('id',outid);
elsif operation='inbox_claim' then
 select * into e from automation.event_inbox where ((state in ('pending','retry') and next_attempt_at<=now()) or (state='processing' and lease_until<now())) and (p->>'id' is null or id=(p->>'id')::uuid) order by received_at for update skip locked limit 1;
 if not found then return null;end if;
 update automation.event_inbox set state='processing',owner=(p->>'owner')::uuid,lease_until=now()+interval '90 seconds',attempts=attempts+1 where id=e.id;
 return jsonb_build_object('id',e.id,'reference',e.reference,'eventType',e.event_type,'occurredAt',e.occurred_at,'attempts',e.attempts+1);
elsif operation='inbox_finish' then
 update automation.event_inbox set state=case when (p->>'ok')::boolean then 'processed' when attempts>=8 then 'blocked' else 'retry' end,error_code=p->>'errorCode',next_attempt_at=now()+make_interval(secs=>least(900,60*power(2,least(attempts,4))::int)),owner=null,lease_until=null where id=(p->>'id')::uuid and owner=(p->>'owner')::uuid;
 if exists(select 1 from automation.event_inbox where id=(p->>'id')::uuid and state='blocked') then perform automation.task('event-blocked:'||(p->>'id'),null,'sync_failure','Automatic event processing needs attention','An event could not be verified after repeated attempts. No combination was sent.');end if;
 return jsonb_build_object('ok',found);
elsif operation='outbox_claim' then
 if cfg.mode<>'live' or not cfg.acceptance_passed or cfg.live_approved_at is null or cfg.activation_at is null or cfg.policy_version is null then return null;end if;
 -- A crashed sender may already have handed the message to Twilio. Never requeue it.
 for n in update automation.notification_outbox set state='unknown',error_code='dispatch_outcome_unknown' where state='dispatching' and dispatch_started_at<now()-interval '120 seconds' returning * loop
 perform automation.task('sms:'||n.id::text,n.facility_id,'sms_failure','SMS outcome needs reconciliation','The provider may have accepted the message. Automatic resend is blocked.',n.assignment_id,n.id,'confirmed','unknown');end loop;
 select * into n from automation.notification_outbox where state='pending' and (p->>'id' is null or id=(p->>'id')::uuid) order by created_at for update skip locked limit 1;
 if not found then return null;end if;
 if n.created_at<now()-interval '120 seconds' or n.source_occurred_at<cfg.activation_at or n.template_version<>cfg.policy_version or not automation.is_current(n) then
 update automation.notification_outbox set state='cancelled',error_code='eligibility_or_assignment_changed' where id=n.id;
 perform automation.task('sms:'||n.id::text,n.facility_id,'assignment_conflict','Notification cancelled before dispatch','The assignment, recipient, consent or eligibility changed. No combination was sent.',n.assignment_id,n.id,'unverified','cancelled');return jsonb_build_object('cancelled',true);end if;
 -- Serialize with ordinary lock mutation while the final dispatch attempt is reserved.
 perform 1 from public.locks where id=n.lock_id and version=n.lock_version for update;
 if not found then return null;end if;
 if not automation.is_current(n) then update automation.notification_outbox set state='cancelled',error_code='assignment_changed' where id=n.id;return jsonb_build_object('cancelled',true);end if;
 select * into s from automation.operational_snapshots where lease_id=n.lease_id;
 select return_instructions into ph from automation.facility_links where facility_id=n.facility_id;
 if nullif(trim(ph),'') is null then update automation.notification_outbox set state='cancelled',error_code='return_instructions_missing' where id=n.id;return jsonb_build_object('cancelled',true);end if;
 aid:=gen_random_uuid();update automation.notification_outbox set state='dispatching',attempt_id=aid,dispatch_started_at=now() where id=n.id;
 insert into automation.notification_attempts(notification_id,event_key,state) values(n.id,'dispatch:'||aid::text,'dispatching');
 return jsonb_build_object('id',n.id,'attemptId',aid,'kind',n.kind,'leaseId',n.lease_id,'sourceFacilityId',s.source_facility_id,'sourceUnitId',s.source_unit_id,'customerId',s.customer_id,'lockId',n.lock_id,'assignmentId',n.assignment_id,'lockVersion',n.lock_version,'phone',extensions.pgp_sym_decrypt(s.phone_encrypted,(select value from private.encryption_key)),
 'facility',s.facility_name,'unit',s.unit_label,'serial',(select serial from public.locks where id=n.lock_id),'combination',(select extensions.pgp_sym_decrypt(encrypted,(select value from private.encryption_key)) from private.lock_secrets where lock_id=n.lock_id),'returnInstructions',ph);
elsif operation in ('outbox_result','delivery_callback') then
 select * into n from automation.notification_outbox where attempt_id=(p->>'attemptId')::uuid for update;
 if not found or (n.provider_sid is not null and n.provider_sid<>p->>'providerSid') then return null;end if;
 incoming:=p->>'state';
 if incoming not in ('accepted','queued','sending','sent','delivered','undelivered','failed','unknown') then return null;end if;
 if n.delivery_status='delivered' then incoming:='delivered';elsif n.delivery_status in ('undelivered','failed') and incoming<>'delivered' then incoming:=n.delivery_status;
 elsif n.delivery_status='sent' and incoming in ('accepted','queued','sending') then incoming:='sent';end if;
 update automation.notification_outbox set provider_sid=coalesce(provider_sid,p->>'providerSid'),delivery_status=incoming,state=case when incoming='delivered' then 'delivered' when incoming in ('failed','undelivered') then 'failed' when incoming='unknown' then 'unknown' else 'submitted' end,submitted_at=coalesce(submitted_at,now()),delivered_at=case when incoming='delivered' then coalesce(delivered_at,now()) else delivered_at end,error_code=p->>'errorCode' where id=n.id;
 insert into automation.notification_attempts(notification_id,event_key,state,provider_sid,error_code) values(n.id,'status:'||n.attempt_id::text||':'||incoming,incoming,p->>'providerSid',p->>'errorCode') on conflict(event_key) do nothing;
 update public.action_items set notification_state=case when incoming='delivered' then 'delivered' when incoming in ('failed','undelivered') then 'failed' when incoming='unknown' then 'unknown' else 'submitted' end,updated_at=now() where notification_id=n.id;
 if incoming in ('failed','undelivered','unknown') then perform automation.task('sms:'||n.id::text,n.facility_id,'sms_failure','Automatic SMS needs attention','Delivery failed or the outcome is uncertain. Review before any resend.',n.assignment_id,n.id,'confirmed',incoming);end if;
 return jsonb_build_object('ok',true);
elsif operation='suppress' then
 insert into automation.sms_suppressions(phone_hash,provider_sid) values(p->>'phoneHash',p->>'providerSid') on conflict(phone_hash) do nothing;
 update automation.sms_consents set revoked_at=now() where phone_hash=p->>'phoneHash' and revoked_at is null;
 update automation.notification_outbox set state='cancelled',error_code='recipient_opted_out' where phone_hash=p->>'phoneHash' and state='pending';
 return jsonb_build_object('ok',true);
end if;
raise exception 'Unknown automation operation';
end $$;
