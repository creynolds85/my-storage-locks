alter table automation.lock_mirror_records add column source_metadata_fingerprint text;
create or replace function automation.lock_mirror_batch(run_id uuid,records jsonb) returns void language plpgsql security definer set search_path='' as $$
declare run automation.lock_mirror_runs;c automation.lock_mirror_control;j jsonb;s automation.lock_mirror_records;l public.locks;a public.assignments;n automation.notification_outbox;
 fid uuid;lid uuid;aid uuid;marker timestamp;fp text;meta_fp text;combo_valid boolean;typ text;purpose boolean;combo_same boolean;binding_same boolean;changed boolean;why text;before_values jsonb;old_facility uuid;
begin
 select * into strict run from automation.lock_mirror_runs where id=run_id and state='processing' for update;
 if jsonb_typeof(records)<>'array' or jsonb_array_length(records)>60 or pg_column_size(records)>200000 then raise exception 'Invalid lock batch';end if;
 for j in select value from jsonb_array_elements(records) loop
  why:=null;lid:=null;fid:=null;marker:=null;l:=null;a:=null;s:=null;
  begin
   if j->>'sourceLockId' !~ '^lock_[A-Za-z0-9]+$' or j->>'sourceLockId' is null then why:='source_identity_unverified';raise exception 'Review required';end if;
   select * into s from automation.lock_mirror_records where source_org_id=run.source_org_id and source_lock_id=j->>'sourceLockId' for update;
   if s.last_seen_run=run.id then raise exception 'Duplicate source identity';end if;
   marker:=(j->>'updatedAt')::timestamp;
   fp:=encode(extensions.hmac((j-'unit'-'unitMatches')::text,(select value from private.encryption_key),'sha256'),'hex');
   meta_fp:=encode(extensions.hmac((j-'unit'-'unitMatches'-'combination'-'combinationAvailable')::text,(select value from private.encryption_key),'sha256'),'hex');
   combo_valid:=jsonb_typeof(j->'combination')='string' and length(j->>'combination') between 1 and 200;
   if marker is null or (s.source_marker is not null and marker<s.source_marker) then why:='older_source_record';raise exception 'Review required';end if;
   if run.snapshot_at<s.source_snapshot_at then why:='older_source_snapshot';raise exception 'Review required';end if;
   if marker=s.source_marker and fp is distinct from s.source_fingerprint and (meta_fp is distinct from s.source_metadata_fingerprint or (s.combination_verified and coalesce(combo_valid,false))) then why:='source_version_conflict';raise exception 'Review required';end if;
   select f.id into fid from public.facilities f join automation.facility_links fl on fl.facility_id=f.id and fl.source_org_id=f.source_org_id and fl.source_facility_id=f.source_facility_id where f.source_org_id=run.source_org_id and f.source_facility_id=j->>'facilityId';
   if fid is null then why:='facility_mapping_unverified';raise exception 'Review required';end if;
   select * into l from public.locks where source_org_id=run.source_org_id and source_lock_id=j->>'sourceLockId' for update nowait;lid:=l.id;old_facility:=l.facility_id;
   if j->>'serial' !~ '^[A-Za-z0-9]{1,100}$' or j->>'serial' is null or (l.id is not null and l.serial is distinct from j->>'serial') or exists(select 1 from public.locks x where x.facility_id=fid and lower(x.serial)=lower(j->>'serial') and x.id is distinct from l.id) then why:='serial_identity_conflict';raise exception 'Review required';end if;
   if j->>'status' not in ('ACTIVE','IN_TENANT','AVAILABLE','MISSING','DAMAGED') or j->>'status' is null then why:='source_status_unverified';raise exception 'Review required';end if;
   if j->>'status' in ('ACTIVE','IN_TENANT') then
    if j->>'unitId' is null or nullif(j->>'unit','') is null or (j->>'unitMatches')::int<>1 or exists(select 1 from automation.unit_links u where u.source_org_id=run.source_org_id and u.source_unit_id=j->>'unitId' and (u.facility_id<>fid or u.label<>j->>'unit')) then why:='unit_mapping_unverified';raise exception 'Review required';end if;
   elsif j->>'unitId' is not null or j->>'unit' is not null then why:='status_assignment_conflict';raise exception 'Review required';end if;
   if s.lock_id is not null and s.local_version is distinct from l.version then why:='local_change_after_sync';raise exception 'Review required';end if;
   if l.id is not null and marker<(l.source_updated_at at time zone 'UTC') then why:='older_than_import';raise exception 'Review required';end if;
   if fp=s.applied_fingerprint and l.version=s.local_version and l.facility_id=fid and l.unit is not distinct from j->>'unit' then
    update automation.lock_mirror_records set last_seen_run=run.id,last_seen_at=now(),source_snapshot_at=run.snapshot_at,issue=case when not combination_verified then 'combination_unavailable' when purpose_verified then null else 'purpose_unverified' end where source_org_id=run.source_org_id and source_lock_id=j->>'sourceLockId';
    continue;
   end if;
   select * into a from public.assignments where lock_id=l.id and released_at is null for update nowait;
   binding_same:=l.facility_id=fid and l.unit is not distinct from j->>'unit' and (case when j->>'unitId' is null then a.id is null else a.id is not null and a.facility_id=fid and a.unit=l.unit and a.type=l.status end);
   purpose:=true;
   typ:=case j->>'status' when 'AVAILABLE' then case when j->>'needsMaintenance'='true' then 'maintenance' else 'available' end when 'MISSING' then 'missing' when 'DAMAGED' then 'damaged' when 'IN_TENANT' then 'tenant_held' end;
   if j->>'status'='ACTIVE' then
    -- No inference from occupancy, color or arbitrary custom-location text.
    purpose:=false;
    typ:=case when binding_same and l.status in ('vacant','overlock','auction','unclassified') then l.status else 'unclassified' end;
    if marker=(l.source_updated_at at time zone 'UTC') and l.source_unit_id=j->>'unitId' and l.source_status='ACTIVE' and l.source_display_status in ('On vacant unit','Overlocked','Locked for auction') then
     purpose:=true;typ:=case l.source_display_status when 'On vacant unit' then 'vacant' when 'Overlocked' then 'overlock' else 'auction' end;
    elsif binding_same and exists(select 1 from private.lock_assignment_reconciliations r where r.lock_id=l.id and r.after_binding->>'unit'=j->>'unit' and r.after_binding->>'status'=l.status and r.source_updated_at at time zone 'UTC'=marker and r.reason like 'Owner-confirmed%') then purpose:=true;
    end if;
    if not coalesce(purpose,false) then why:='purpose_unverified';end if;
   end if;
   if not coalesce(combo_valid,false) then why:=case when j->>'combinationAvailable'='false' then 'combination_unavailable' else 'combination_unverified' end;end if;
   combo_same:=not coalesce(combo_valid,false) or (l.id is not null and exists(select 1 from private.lock_secrets x where x.lock_id=l.id and extensions.pgp_sym_decrypt(x.encrypted,(select value from private.encryption_key))=j->>'combination'));
   if s.lock_id is null and l.version>1 and (not coalesce(binding_same,false) or l.status is distinct from typ or not combo_same) then why:='local_baseline_conflict';raise exception 'Review required';end if;
   before_values:=case when l.id is not null then jsonb_build_object('facilityId',l.facility_id,'unit',l.unit,'status',l.status,'version',l.version,'assignmentId',a.id) end;
   changed:=l.id is null or not combo_same or l.facility_id is distinct from fid or l.unit is distinct from j->>'unit' or l.status is distinct from typ or not coalesce(binding_same,false);
   if changed and l.id is not null then
    for n in select * from automation.notification_outbox where lock_id=l.id and state in ('pending','dry_run','dispatching','unknown') order by id for update nowait loop
     if n.state in ('dispatching','unknown') then why:='notification_outcome_unresolved';raise exception 'Review required';end if;
     update automation.notification_outbox set state='cancelled',error_code='cubby_lock_changed' where id=n.id;
     insert into automation.notification_attempts(notification_id,event_key,state,error_code) values(n.id,'lock-mirror:'||run.id||':'||n.id,'cancelled','cubby_lock_changed') on conflict(event_key) do nothing;
     update public.action_items set notification_state='cancelled',updated_at=now() where notification_id=n.id;
    end loop;
   end if;
   if l.id is null then
    insert into public.locks(serial,color,facility_id,status,unit,source_org_id,source_lock_id,source_unit_id,source_status,source_updated_at,source_created_at,source_needs_maintenance,source_custom_location,imported_at)
    values(j->>'serial','Unknown',fid,typ,j->>'unit',run.source_org_id,j->>'sourceLockId',j->>'unitId',j->>'status',marker at time zone 'UTC',(j->>'createdAt')::timestamp at time zone 'UTC',(j->>'needsMaintenance')::boolean,j->>'customLocation',now()) returning * into l;lid:=l.id;
   elsif changed then
    update public.locks set facility_id=fid,status=typ,unit=j->>'unit',version=version+1,updated_at=clock_timestamp() where id=l.id returning * into l;
   end if;
   if coalesce(combo_valid,false) and not combo_same then
    insert into private.lock_secrets(lock_id,encrypted) values(l.id,extensions.pgp_sym_encrypt(j->>'combination',(select value from private.encryption_key))) on conflict(lock_id) do update set encrypted=excluded.encrypted;
   end if;
   if a.id is not null and (a.facility_id<>fid or a.unit is distinct from j->>'unit' or a.type<>typ) then
    -- Close the observed binding, not a claim that an MSL employee recovered it.
    update public.assignments set released_at=now(),released_by=null where id=a.id;aid:=null;
   else aid:=a.id;end if;
   if j->>'unitId' is not null then
    if aid is null then insert into public.assignments(lock_id,facility_id,unit,type,assigned_by,assigned_at,imported_at) values(l.id,fid,j->>'unit',typ,null,null,now()) returning id into aid;end if;
    insert into automation.assignment_links(assignment_id,source_org_id,source_unit_id,linked_at) values(aid,run.source_org_id,j->>'unitId',now()) on conflict(assignment_id) do update set source_unit_id=excluded.source_unit_id,linked_at=case when automation.assignment_links.source_unit_id<>excluded.source_unit_id then excluded.linked_at else automation.assignment_links.linked_at end;
   end if;
   if changed then insert into public.activity(lock_id,facility_id,actor_id,action,before_values,after_values) values(l.id,fid,null,case when not combo_same then 'cubby_mirror_combination_and_inventory' else 'cubby_mirror_inventory' end,before_values,jsonb_build_object('facilityId',fid,'unit',l.unit,'status',l.status,'version',l.version,'sourceSnapshotAt',run.snapshot_at,'sourceUpdatedMarker',marker,'physicalRecoveryConfirmed',false));end if;
   insert into automation.lock_mirror_records(source_org_id,source_lock_id,lock_id,source_facility_id,source_unit_id,unit_label,source_status,source_marker,source_snapshot_at,source_fingerprint,source_metadata_fingerprint,applied_fingerprint,local_version,purpose_verified,combination_verified,needs_maintenance,custom_location,last_seen_run,issue)
   values(run.source_org_id,j->>'sourceLockId',l.id,j->>'facilityId',j->>'unitId',j->>'unit',j->>'status',marker,run.snapshot_at,fp,meta_fp,fp,l.version,coalesce(purpose,false),coalesce(combo_valid,false),(j->>'needsMaintenance')::boolean,j->>'customLocation',run.id,why)
   on conflict(source_org_id,source_lock_id) do update set lock_id=excluded.lock_id,source_facility_id=excluded.source_facility_id,source_unit_id=excluded.source_unit_id,unit_label=excluded.unit_label,source_status=excluded.source_status,source_marker=excluded.source_marker,source_snapshot_at=excluded.source_snapshot_at,source_fingerprint=excluded.source_fingerprint,source_metadata_fingerprint=excluded.source_metadata_fingerprint,applied_fingerprint=excluded.applied_fingerprint,local_version=excluded.local_version,purpose_verified=excluded.purpose_verified,combination_verified=excluded.combination_verified,needs_maintenance=excluded.needs_maintenance,custom_location=excluded.custom_location,last_seen_run=excluded.last_seen_run,last_seen_at=now(),issue=excluded.issue;
  exception when others then
   -- Deliberately never persist SQLERRM, request JSON, or plaintext combinations.
   if j->>'sourceLockId' ~ '^lock_[A-Za-z0-9]+$' then
    insert into automation.lock_mirror_records(source_org_id,source_lock_id,lock_id,source_facility_id,source_unit_id,unit_label,source_status,source_marker,source_snapshot_at,last_seen_run,issue)
    values(run.source_org_id,j->>'sourceLockId',lid,j->>'facilityId',j->>'unitId',j->>'unit',j->>'status',null,run.snapshot_at,run.id,case when why is null or why='purpose_unverified' then 'record_conflict_'||sqlstate else why end)
    on conflict(source_org_id,source_lock_id) do update set issue=excluded.issue,last_seen_run=run.id,last_seen_at=now();
   end if;
  end;
 end loop;
 update automation.lock_mirror_runs set received=received+jsonb_array_length(records) where id=run.id;
end $$;
create or replace function automation.lock_mirror_report() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('mode',c.mode,'enabled',c.enabled,'lastCheckedAt',c.last_checked_at,'lastSuccessAt',c.last_success_at,'sourceSnapshotAt',c.last_snapshot_at,
 'sourceAgeSeconds',extract(epoch from now()-c.last_snapshot_at),'lastErrorCode',c.last_error_code,
 'sourceLocks',(select count(*) from automation.lock_mirror_records r where r.last_seen_run=c.last_run_id),
 'matched',(select count(*) from automation.lock_mirror_records r join public.locks l on l.id=r.lock_id where r.last_seen_run=c.last_run_id and r.issue is null and l.version=r.local_version),
 'combinationVerified',(select count(*) from automation.lock_mirror_records where last_seen_run=c.last_run_id and combination_verified),'purposeUnverified',(select count(*) from automation.lock_mirror_records where last_seen_run=c.last_run_id and source_status='ACTIVE' and not purpose_verified),'fieldsMatched',(select count(*) from automation.lock_mirror_records r join public.locks l on l.id=r.lock_id where r.last_seen_run=c.last_run_id and r.applied_fingerprint=r.source_fingerprint and (r.issue is null or r.issue in ('purpose_unverified','combination_unavailable','combination_unverified')) and l.version=r.local_version),
 'unresolved',(select count(*) from automation.lock_mirror_records r left join public.locks l on l.id=r.lock_id where r.issue is not null or l.id is null or l.version is distinct from r.local_version),
 'issues',coalesce((select jsonb_object_agg(reason,n) from (select coalesce(case when l.version is distinct from r.local_version then 'local_change_or_unapplied' else r.issue end,'unmatched') reason,count(*) n from automation.lock_mirror_records r left join public.locks l on l.id=r.lock_id where r.issue is not null or l.id is null or l.version is distinct from r.local_version group by 1) q),'{}'::jsonb),
 'localOnlyLocks',(select count(*) from public.locks l where not exists(select 1 from automation.lock_mirror_records r where r.lock_id=l.id and r.last_seen_run=c.last_run_id)),
 'capabilities',(select capabilities from automation.lock_mirror_runs where id=c.last_run_id),'combinationsReturned',false,
 'inventoryLocks',(select count(*) from public.locks),'details',coalesce((select jsonb_agg(x) from (select r.source_lock_id as "sourceLockId",l.serial,r.unit_label as unit,r.issue,l.version is distinct from r.local_version as "localChanged" from automation.lock_mirror_records r left join public.locks l on l.id=r.lock_id where r.issue is not null or l.id is null or l.version is distinct from r.local_version order by r.source_facility_id,l.serial limit 500) x),'[]'::jsonb))
 from automation.lock_mirror_control c where c.id;
$$;
do $$declare definition text;begin
 definition:=pg_get_functiondef('private.walkthrough_expected(uuid,jsonb)'::regprocedure);
 definition:=replace(definition,'r.issue is not null or l.version', '(r.issue is not null and r.issue not in (''combination_unavailable'',''combination_unverified'')) or (r.source_status=''ACTIVE'' and not r.purpose_verified) or l.version');execute definition;
end $$;
