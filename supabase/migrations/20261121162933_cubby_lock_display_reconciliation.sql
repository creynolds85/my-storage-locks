create table automation.lock_mirror_display_evidence (
 source_org_id text not null,
 source_lock_id text not null,
 source_facility_id text not null,
 source_unit_id text,
 source_marker timestamp not null,
 display_status text not null,
 observed_at timestamptz not null,
 source text not null check (source in ('combo_locks_export','bigquery_display_status')),
 primary key (source_org_id,source_lock_id)
);
alter table automation.lock_mirror_display_evidence enable row level security;
revoke all on automation.lock_mirror_display_evidence from public,anon,authenticated;

create function automation.cubby_lock_display_type(label text, broad text, maintenance boolean)
returns text language sql immutable security invoker set search_path='' as $$
 select case
  when broad='ACTIVE' then case label when 'On vacant unit' then 'vacant' when 'Overlocked' then 'overlock' when 'Locked for auction' then 'auction' end
  when broad='AVAILABLE' and label in ('Available','For maintenance') then case when maintenance then 'maintenance' else 'available' end
  when broad='IN_TENANT' and label in ('Used by tenant','For maintenance') then 'tenant_held'
  when broad='MISSING' and label='Missing' then 'missing'
  when broad='DAMAGED' and label='Damaged' then 'damaged'
 end
$$;
revoke all on function automation.cubby_lock_display_type(text,text,boolean) from public,anon,authenticated;

-- Accept only administrative, secret-free exports independently joined to immutable
-- Cubby lock/unit IDs and source update markers. Protect against the scheduler
-- advancing the last complete snapshot while the export batch is being applied.
create function automation.reconcile_cubby_lock_display(org text, observed timestamptz, records jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare c automation.lock_mirror_control; result jsonb;
begin
 if org !~ '^org_[A-Za-z0-9]+$' or org is null or observed is null
  or observed < now()-interval '95 minutes' or observed > now()+interval '2 minutes'
  or jsonb_typeof(records) is distinct from 'array' then raise exception 'Invalid Cubby Combo Locks evidence';end if;
 if jsonb_array_length(records) not between 1 and 3000
  or (select count(distinct j->>'id') from jsonb_array_elements(records) j)<>jsonb_array_length(records)
  or exists (select 1 from jsonb_array_elements(records) j where jsonb_typeof(j) <> 'object'
    or j-'{id,fac,unitid,unit,serial,marker,status,label}'::text[] <> '{}'::jsonb)
 then raise exception 'Invalid Cubby Combo Locks evidence rows';end if;
 select * into strict c from automation.lock_mirror_control where id for update;
 if c.mode<>'mirror' or not c.enabled or c.lease_until>now()
  or c.last_snapshot_at is null or c.last_snapshot_at<now()-interval '95 minutes'
  or not exists(select 1 from automation.lock_mirror_runs q where q.id=c.last_run_id and q.state='complete' and q.source_org_id=org)
 then raise exception 'A current completed Cubby mirror snapshot is required';end if;

 with input as (
  select * from jsonb_to_recordset(records) as j(id text,fac text,unitid text,unit text,serial text,marker timestamp,status text,label text)
 ), source_match as materialized (
  select r.*,j.serial,j.label,automation.cubby_lock_display_type(j.label,r.source_status,r.needs_maintenance) as target
  from input j join automation.lock_mirror_records r on r.source_org_id=org and r.source_lock_id=j.id
  join public.locks identity on identity.id=r.lock_id and identity.source_org_id=org
   and identity.source_lock_id=r.source_lock_id and identity.serial=j.serial
  where r.last_seen_run=c.last_run_id and r.source_marker=j.marker and r.source_facility_id=j.fac and r.source_status=j.status
   and r.source_unit_id is not distinct from j.unitid and r.unit_label is not distinct from j.unit
   and (automation.cubby_lock_display_type(j.label,r.source_status,r.needs_maintenance) is not null
    or (r.source_status='ACTIVE' and j.label in ('Locked','Remove lock')))
 ), evidence as (
  insert into automation.lock_mirror_display_evidence as e (source_org_id,source_lock_id,source_facility_id,source_unit_id,source_marker,display_status,observed_at,source)
  select source_org_id,source_lock_id,source_facility_id,source_unit_id,source_marker,label,observed,'combo_locks_export'
  from source_match
  on conflict(source_org_id,source_lock_id) do update set source_facility_id=excluded.source_facility_id,source_unit_id=excluded.source_unit_id,
   source_marker=excluded.source_marker,display_status=excluded.display_status,observed_at=excluded.observed_at,source=excluded.source
  where excluded.observed_at>e.observed_at and excluded.source_marker>=e.source_marker
  returning source_org_id,source_lock_id
 ), eligible as materialized (
  select l.id,l.facility_id,l.unit,l.status,l.version,a.id as assignment_id,s.source_org_id,s.source_lock_id,s.source_marker,s.label,s.target
  from source_match s join evidence e using(source_org_id,source_lock_id)
  join public.locks l on l.id=s.lock_id and l.source_org_id=s.source_org_id and l.source_lock_id=s.source_lock_id
  join automation.facility_links f on f.facility_id=l.facility_id and f.source_org_id=s.source_org_id and f.source_facility_id=s.source_facility_id
  join public.assignments a on a.lock_id=l.id and a.released_at is null and a.facility_id=l.facility_id and a.unit=l.unit and a.type=l.status
  join automation.assignment_links x on x.assignment_id=a.id and x.source_org_id=s.source_org_id and x.source_unit_id=s.source_unit_id
  where s.source_status='ACTIVE' and s.target is not null and l.unit=s.unit_label and l.serial=s.serial and l.version=s.local_version
   and s.applied_fingerprint=s.source_fingerprint and (s.issue is null or s.issue in ('combination_unavailable','combination_unverified','purpose_unverified'))
   and l.status in ('vacant','overlock','auction','unclassified') and (l.status<>s.target or not s.purpose_verified)
   and not exists(select 1 from automation.notification_outbox n where n.lock_id=l.id and n.state in ('pending','dry_run','dispatching','unknown'))
  order by l.id for no key update of l,a
 ), changed as (
  update public.locks l set status=q.target,version=l.version+1,updated_at=clock_timestamp()
  from eligible q where l.id=q.id and q.status<>q.target returning l.id,l.version
 ), bindings as (
  update public.assignments a set type=q.target from eligible q join changed l on l.id=q.id where a.id=q.assignment_id returning a.id
 ), mirrored as (
  update automation.lock_mirror_records r set purpose_verified=true,local_version=coalesce(l.version,q.version),
   issue=case when r.issue='purpose_unverified' then null else r.issue end
  from eligible q left join changed l on l.id=q.id left join bindings b on b.id=q.assignment_id
  where r.source_org_id=q.source_org_id and r.source_lock_id=q.source_lock_id and (l.id is null or b.id is not null)
  returning r.lock_id
 ), audits as (
  insert into private.lock_assignment_reconciliations(lock_id,facility_id,source_lock_id,source_observed_at,source_updated_at,before_binding,after_binding,reason)
  select q.id,q.facility_id,q.source_lock_id,observed,q.source_marker at time zone 'UTC',
   jsonb_build_object('facilityId',q.facility_id,'unit',q.unit,'status',q.status,'version',q.version,'assignmentId',q.assignment_id),
   jsonb_build_object('facilityId',q.facility_id,'unit',q.unit,'status',q.target,'version',coalesce(l.version,q.version),'assignmentId',q.assignment_id,'cubbyDisplayStatus',q.label),
   'Owner-confirmed authority: exact Combo Locks export label corroborated by the current immutable Cubby lock, facility, unit and lock timestamp.'
  from eligible q join mirrored m on m.lock_id=q.id left join changed l on l.id=q.id
  returning lock_id,facility_id,before_binding,after_binding
 ), activity as (
  insert into public.activity(lock_id,facility_id,action,before_values,after_values)
  select lock_id,facility_id,'cubby_assignment_reconciled',before_binding,after_binding
  from audits where before_binding->>'status'<>after_binding->>'status' returning lock_id
 )
 select jsonb_build_object('submitted',(select count(*) from input),'sourceMatched',(select count(*) from source_match),
  'evidenceRecorded',(select count(*) from evidence),'verifiedPurposes',(select count(*) from mirrored),
  'corrected',(select count(*) from activity),
  'correctedFromUnclassified',(select count(*) from audits where before_binding->>'status'='unclassified'),
  'correctionsByStatus',coalesce((select jsonb_object_agg(status,n) from
   (select after_binding->>'status' status,count(*) n from audits where before_binding->>'status'<>after_binding->>'status' group by 1) q),'{}'::jsonb))
 into result;
 return result;
end $$;
revoke all on function automation.reconcile_cubby_lock_display(text,timestamptz,jsonb) from public,anon,authenticated;

create function automation.lock_mirror_inventory_coverage() returns jsonb
language sql stable security invoker set search_path='' as $$
 with current_rows as (
  select r.*, l.status as msl_status,l.version,
   f.source_facility_id is not distinct from r.source_facility_id and f.facility_id is not null
    and l.unit is not distinct from r.unit_label
    and case when r.source_unit_id is null then a.id is null
             else a.facility_id=l.facility_id and a.unit=l.unit and a.type=l.status
              and x.source_unit_id=r.source_unit_id and x.source_org_id=r.source_org_id end as placement,
   e.display_status,e.observed_at,
   automation.cubby_lock_display_type(e.display_status,r.source_status,r.needs_maintenance) as display_type
  from automation.lock_mirror_control c join automation.lock_mirror_records r on r.last_seen_run=c.last_run_id
  left join public.locks l on l.id=r.lock_id and l.source_org_id=r.source_org_id and l.source_lock_id=r.source_lock_id
  left join automation.facility_links f on f.facility_id=l.facility_id and f.source_org_id=r.source_org_id
  left join public.assignments a on a.lock_id=l.id and a.released_at is null
  left join automation.assignment_links x on x.assignment_id=a.id
  left join automation.lock_mirror_display_evidence e on e.source_org_id=r.source_org_id and e.source_lock_id=r.source_lock_id
   and e.source_facility_id=r.source_facility_id and e.source_unit_id is not distinct from r.source_unit_id
   and e.source_marker=r.source_marker
 ), classified as (
  select *, case
   when version is null then 'identity_unverified'
   when not coalesce(placement,false) then 'binding_mismatch'
   when version is distinct from local_version or applied_fingerprint is distinct from source_fingerprint
     or issue not in ('combination_unavailable','combination_unverified','purpose_unverified') then 'source_or_local_conflict'
   when display_type is not null and display_type<>msl_status then 'display_status_mismatch'
   when source_status='ACTIVE' and not purpose_verified then case display_status
     when 'Locked' then 'cubby_locked_no_purpose' when 'Remove lock' then 'cubby_remove_lock_no_purpose' else 'purpose_not_available' end
   when not combination_verified then 'combination_not_verified'
   else 'verified' end as result
  from current_rows
 )
 select jsonb_build_object(
  'records',(select count(*) from classified),
  'placementMatched',(select count(*) from classified where placement and result not in ('source_or_local_conflict','identity_unverified')),
  'exactDisplayEvidence',(select count(*) from classified where display_status is not null),
  'lastDisplayObservedAt',(select max(observed_at) from classified),
  'results',coalesce((select jsonb_object_agg(result,n) from (select result,count(*) n from classified group by result) q),'{}'::jsonb),
  'unclassifiedReasons',coalesce((select jsonb_object_agg(result,n) from (select result,count(*) n from classified where msl_status='unclassified' group by result) q),'{}'::jsonb))
$$;
revoke all on function automation.lock_mirror_inventory_coverage() from public,anon,authenticated;

do $migration$
declare definition text:=pg_get_functiondef('automation.lock_mirror_report()'::regprocedure);
 anchor text:='from automation.lock_mirror_control c where c.id;';
begin
 if strpos(definition,anchor)=0 then raise exception 'Lock mirror reporting integration point changed';end if;
 execute replace(definition,anchor,'||jsonb_build_object(''coverage'',automation.lock_mirror_inventory_coverage()) '||anchor);
end
$migration$;

-- A vendor-confirmed warehouse column can supply the same exact labels unattended.
-- Keep reporting fingerprints stable when the optional display field is absent.
do $migration$
declare definition text:=pg_get_functiondef('automation.lock_mirror_batch(uuid,jsonb)'::regprocedure);
 declaration text:='source_color text;prior_color text;';
 guard text:='and (source_color is null or l.color=source_color) then';
 mapping text:='if not coalesce(combo_valid,false) then why:=case';
 binding text:='if a.id is not null and (a.facility_id<>fid';
 audit text:='if prior_color is not null and prior_color is distinct from l.color then';
begin
 if strpos(definition,declaration)=0 or strpos(definition,guard)=0 or strpos(definition,mapping)=0
  or strpos(definition,binding)=0 or strpos(definition,audit)=0 then
  raise exception 'Lock mirror batch integration point changed';
 end if;
 definition:=replace(definition,declaration,declaration||'direct_label text;direct_type text;');
 definition:=replace(definition,$old$j:=j-'physicalColor';$old$,$new$
   direct_label:=case when run.capabilities->>'explicitPurpose'='true'
    and run.capabilities->>'lockDisplayStatusColumn' in ('display_status','lock_display_status','operational_status')
    then j->>'sourceDisplayStatus' end;
   direct_type:=automation.cubby_lock_display_type(direct_label,j->>'status',(j->>'needsMaintenance')::boolean);
   if (direct_type is null and not coalesce(j->>'status'='ACTIVE' and direct_label in ('Locked','Remove lock'),false))
    or exists(select 1 from automation.lock_mirror_display_evidence e
     where e.source_org_id=run.source_org_id and e.source_lock_id=j->>'sourceLockId' and e.observed_at>run.snapshot_at)
   then direct_label:=null;direct_type:=null;end if;
   j:=j-'physicalColor'-'sourceDisplayStatus';$new$);
 definition:=replace(definition,guard,'and (source_color is null or l.color=source_color) and direct_label is null then');
 definition:=replace(definition,mapping,$new$
   if direct_label is not null and j->>'status'='ACTIVE' then
    purpose:=direct_type is not null;
    typ:=coalesce(direct_type,case when binding_same and l.status in ('vacant','overlock','auction') then l.status else 'unclassified' end);
    why:=case when purpose then null else 'purpose_unverified' end;
   end if;
   $new$||mapping);
 definition:=replace(definition,binding,$new$
   if direct_type is not null and direct_type=typ and binding_same and a.id is not null and a.type<>typ then
    update public.assignments set type=typ where id=a.id;
    a.type:=typ;
   end if;
   $new$||binding);
 definition:=replace(definition,audit,$new$
   if direct_label is not null then
    insert into automation.lock_mirror_display_evidence as e
     (source_org_id,source_lock_id,source_facility_id,source_unit_id,source_marker,display_status,observed_at,source)
    values(run.source_org_id,j->>'sourceLockId',j->>'facilityId',j->>'unitId',marker,direct_label,run.snapshot_at,'bigquery_display_status')
    on conflict(source_org_id,source_lock_id) do update set source_facility_id=excluded.source_facility_id,source_unit_id=excluded.source_unit_id,
     source_marker=excluded.source_marker,display_status=excluded.display_status,observed_at=excluded.observed_at,source=excluded.source
    where excluded.observed_at>=e.observed_at and excluded.source_marker>=e.source_marker
     and (excluded.source_marker,excluded.source_facility_id,excluded.source_unit_id,excluded.display_status,excluded.source)
      is distinct from (e.source_marker,e.source_facility_id,e.source_unit_id,e.display_status,e.source);
   end if;
   $new$||audit);
 if strpos(definition,'j:=j-''physicalColor''-''sourceDisplayStatus'';')=0 then
  raise exception 'Lock display status selection integration point changed';
 end if;
 execute definition;
end
$migration$;
