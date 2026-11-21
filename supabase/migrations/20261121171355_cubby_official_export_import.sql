-- Keep export verification separate from values verified by the warehouse worker.
alter table automation.lock_mirror_records
 add column export_combination_verified_at timestamptz,
 add column export_combination_verified_marker timestamp,
 add column export_combination_verified_version int;

create function automation.reconcile_cubby_official_export(fid uuid, observed timestamptz, records jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare ctrl automation.lock_mirror_control; run automation.lock_mirror_runs; result jsonb; detail jsonb;
 matched jsonb; item record; saved int:=0; confirmed int:=0; different int:=0; empty_codes int:=0; blocked int:=0; lv int;
begin
 if observed is null or observed<now()-interval '95 minutes' or observed>now()+interval '2 minutes'
  or jsonb_typeof(records) is distinct from 'array' then return '{"error":"Export must be recent"}'::jsonb;end if;
 if jsonb_array_length(records) not between 1 and 1000 or pg_column_size(records)>400000
  or (select count(distinct lower(j->>'serial')) from jsonb_array_elements(records) j)<>jsonb_array_length(records)
  or exists(select 1 from jsonb_array_elements(records) j where jsonb_typeof(j)<>'object'
   or j-'{serial,unit,label,combination,sourceLockId}'::text[]<>'{}'::jsonb or coalesce(j->>'serial','')!~'^[A-Za-z0-9]{1,100}$'
   or length(coalesce(j->>'combination',''))>200)
 then return '{"error":"Invalid or duplicate export rows"}'::jsonb;end if;

 select * into strict ctrl from automation.lock_mirror_control where id for update;
 select * into run from automation.lock_mirror_runs where id=ctrl.last_run_id and state='complete';
 if ctrl.mode<>'mirror' or not ctrl.enabled or ctrl.lease_until>now() or run.id is null
  or ctrl.last_snapshot_at<now()-interval '95 minutes' or observed<ctrl.last_snapshot_at
 then return '{"error":"Wait for the current Cubby sync, then download and upload a fresh export"}'::jsonb;end if;

 with matches as (
  select l.id as local_id, r.source_lock_id as id,r.source_facility_id as fac,r.source_unit_id as unitid,r.unit_label as unit,
   l.serial,r.source_marker as marker,r.source_status as status,j.label,j.combination
  from jsonb_to_recordset(records) j(serial text,unit text,label text,combination text,"sourceLockId" text)
  join public.locks l on l.facility_id=fid and l.serial=j.serial
  join automation.lock_mirror_records r on r.lock_id=l.id and r.source_lock_id=l.source_lock_id
   and r.source_org_id=l.source_org_id and r.source_org_id=run.source_org_id and r.last_seen_run=run.id
  join automation.facility_links f on f.facility_id=fid and f.source_org_id=r.source_org_id and f.source_facility_id=r.source_facility_id
  left join public.assignments a on a.lock_id=l.id and a.released_at is null
  left join automation.assignment_links x on x.assignment_id=a.id
  where l.version=r.local_version and r.applied_fingerprint=r.source_fingerprint
   and (j."sourceLockId" is null or j."sourceLockId"=r.source_lock_id)
   and l.unit is not distinct from j.unit and r.unit_label is not distinct from j.unit
   and (r.issue is null or r.issue in ('combination_unavailable','combination_unverified','purpose_unverified'))
   and case when r.source_unit_id is null then a.id is null else
    a.facility_id=l.facility_id and a.unit=l.unit and a.type=l.status
     and x.source_unit_id=r.source_unit_id and x.source_org_id=r.source_org_id end
   and (automation.cubby_lock_display_type(j.label,r.source_status,r.needs_maintenance) is not null
    or (r.source_status='ACTIVE' and j.label in ('Locked','Remove lock')))
 )
 select coalesce(jsonb_agg(to_jsonb(m)),'[]'::jsonb) into matched from matches m;

 if jsonb_array_length(matched)>0 then
  detail:=automation.reconcile_cubby_lock_display(run.source_org_id,observed,
   (select jsonb_agg(x-'local_id'-'combination') from jsonb_array_elements(matched) x));
 else detail:='{"corrected":0}'::jsonb;end if;

 for item in
  select m.id,m.marker,m.combination,l.id as local_id,l.version,s.encrypted
  from jsonb_to_recordset(matched) m(id text,marker timestamp,combination text,local_id uuid)
  join public.locks l on l.id=m.local_id
  join automation.lock_mirror_records mr on mr.lock_id=l.id and l.version=mr.local_version
  left join private.lock_secrets s on s.lock_id=l.id
  order by l.id for no key update of l
 loop
  if nullif(item.combination,'') is null then empty_codes:=empty_codes+1;continue;end if;
  lv:=item.version;
  if item.encrypted is null then
   if exists(select 1 from automation.notification_outbox n where n.lock_id=item.local_id
     and n.state in ('pending','dry_run','dispatching','unknown')) then blocked:=blocked+1;continue;end if;
   insert into private.lock_secrets(lock_id,encrypted) values(item.local_id,extensions.pgp_sym_encrypt(item.combination,(select value from private.encryption_key)));
   update public.locks set version=version+1,updated_at=clock_timestamp() where id=item.local_id returning version into lv;
   insert into public.activity(lock_id,facility_id,actor_id,action,after_values)
    values(item.local_id,fid,auth.uid(),'cubby_export_combination_recovered',
      jsonb_build_object('version',lv,'sourceLockId',item.id,'sourceMarker',item.marker,'observedAt',observed));
   saved:=saved+1;
  elsif extensions.pgp_sym_decrypt(item.encrypted,(select value from private.encryption_key)) is distinct from item.combination then
   different:=different+1;
   continue;
  else confirmed:=confirmed+1;end if;
  update automation.lock_mirror_records set local_version=lv,
   export_combination_verified_at=observed,export_combination_verified_marker=item.marker,export_combination_verified_version=lv
   where source_org_id=run.source_org_id and source_lock_id=item.id
    and (export_combination_verified_at is null or export_combination_verified_at<=observed or export_combination_verified_marker is distinct from item.marker);
 end loop;
 result:=jsonb_build_object('submitted',jsonb_array_length(records),'matched',jsonb_array_length(matched),
  'unmatched',jsonb_array_length(records)-jsonb_array_length(matched),'classificationsCorrected',detail->'corrected',
  'combinationsRecovered',saved,'combinationsMatched',confirmed,'combinationConflicts',different,
  'combinationValuesMissing',empty_codes,'blockedByNotification',blocked);
 return result;
exception when others then
 -- Never return database error detail or the submitted file.
 return '{"error":"Cubby export could not be reconciled. No changes were applied."}'::jsonb;
end $$;
revoke all on function automation.reconcile_cubby_official_export(uuid,timestamptz,jsonb) from public,anon,authenticated;

create function public.import_cubby_combo_export(facility uuid, observed_at timestamptz, records jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.live() or not private.admin() then raise exception 'Administrator access required' using errcode='42501';end if;
 return automation.reconcile_cubby_official_export(facility,observed_at,records);
end $$;
revoke all on function public.import_cubby_combo_export(uuid,timestamptz,jsonb) from public,anon;
grant execute on function public.import_cubby_combo_export(uuid,timestamptz,jsonb) to authenticated;

do $migration$
declare d text:=pg_get_functiondef('automation.lock_mirror_worker(text,jsonb)'::regprocedure);
 anchor text:=$old$if operation='lock_mirror_report' then$old$;
begin
 if strpos(d,anchor)=0 then raise exception 'Cubby worker integration point changed';end if;
 execute replace(d,anchor,$new$if operation='lock_mirror_official_export' then
  return automation.reconcile_cubby_official_export((p->>'facility')::uuid,(p->>'observedAt')::timestamptz,p->'records');
 end if;
 $new$||anchor);
 d:=pg_get_functiondef('automation.lock_mirror_report()'::regprocedure);
 anchor:=$old$from automation.lock_mirror_control c where c.id;$old$;
 if strpos(d,anchor)=0 then raise exception 'Cubby report integration point changed';end if;
 execute replace(d,anchor,$new$||jsonb_build_object('exportCombinationsVerified',(
  select count(*) from automation.lock_mirror_records r join public.locks l on l.id=r.lock_id
  where r.last_seen_run=c.last_run_id and r.export_combination_verified_marker=r.source_marker
   and r.export_combination_verified_version=l.version)) $new$||anchor);
end
$migration$;
