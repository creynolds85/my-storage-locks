-- Record only review metadata the existing importer already establishes.
create table automation.cubby_export_reconciliations (
 id bigint generated always as identity primary key,
 facility_id uuid not null,
 observed_at timestamptz not null,
 reconciled_at timestamptz not null default clock_timestamp(),
 matched_serials text[] not null,
 unmatched_serials text[] not null
);
create index cubby_export_reconciliations_facility on automation.cubby_export_reconciliations
 (facility_id,observed_at desc,id desc);
alter table automation.cubby_export_reconciliations enable row level security;
revoke all on automation.cubby_export_reconciliations from public,anon,authenticated;

alter table automation.lock_mirror_records
 add column export_combination_conflict_at timestamptz,
 add column export_combination_conflict_marker timestamp,
 add column export_combination_conflict_version int;

do $migration$
declare definition text:=pg_get_functiondef('automation.reconcile_cubby_official_export(uuid,timestamptz,jsonb)'::regprocedure);
 conflict_anchor text:=$old$different:=different+1;$old$;
 receipt_anchor text:=$old$result:=jsonb_build_object('submitted',jsonb_array_length(records),$old$;
begin
 if strpos(definition,conflict_anchor)=0 or strpos(definition,receipt_anchor)=0 then
  raise exception 'Cubby export reconciliation integration point changed';
 end if;
 definition:=replace(definition,conflict_anchor,conflict_anchor||$new$
   update automation.lock_mirror_records set export_combination_conflict_at=observed,
    export_combination_conflict_marker=item.marker,export_combination_conflict_version=lv
    where source_org_id=run.source_org_id and source_lock_id=item.id
     and (export_combination_conflict_at is null or export_combination_conflict_at<=observed);
 $new$);
 execute replace(definition,receipt_anchor,$new$
 insert into automation.cubby_export_reconciliations(facility_id,observed_at,matched_serials,unmatched_serials)
 select fid,observed,array(select m->>'serial' from jsonb_array_elements(matched) m),array(
  select submitted->>'serial' from jsonb_array_elements(records) submitted
  where not exists(select 1 from jsonb_array_elements(matched) m where m->>'serial'=submitted->>'serial')
 );
 $new$||receipt_anchor);
end
$migration$;

create function automation.lock_inventory_reconciliation() returns jsonb
language sql stable set search_path='' as $$
 with snapshot as materialized (
  select c.last_run_id,c.last_snapshot_at,c.last_success_at,c.last_error_code,run.source_org_id,
    run.finished_at,report,
    (run.state='complete' and run.received=run.source_count
     and (report->>'sourceLocks')::int=run.source_count) is true as complete,
    (c.last_snapshot_at>=now()-interval '95 minutes') is true as fresh
  from automation.lock_mirror_control c
  left join automation.lock_mirror_runs run on run.id=c.last_run_id
  cross join lateral (select automation.lock_mirror_report() as report) mirror
  where c.id
 ), current_source as materialized (
  select r.* from snapshot s join automation.lock_mirror_records r
   on s.complete and r.last_seen_run=s.last_run_id and r.source_org_id=s.source_org_id
 ), evidence as (
  select l.id as lock_id,l.serial,l.status,l.unit,l.facility_id,r.source_lock_id,l.source_lock_id as local_source_id,r.unit_label as source_unit,
   r.lock_id as source_link,r.local_version,r.issue,r.source_status,r.purpose_verified,previous.source_status as prior_source_status,
   d.display_status,automation.cubby_lock_display_type(d.display_status,r.source_status,r.needs_maintenance) as display_type,
   r.applied_fingerprint=r.source_fingerprint as fingerprint_matches,l.version,
   s.complete,s.fresh,
   f.name as facility,coalesce(sf.name,r.source_facility_id) as source_facility,
   l.source_lock_id is not null and l.source_org_id=s.source_org_id as local_identity,
   previous.issue='source_record_missing' as was_retained,
   k.encrypted is not null as has_code,
   m.facility_id is not null and m.facility_id=l.facility_id and l.unit is not distinct from r.unit_label
    and case when r.source_unit_id is null then a.id is null
     else a.facility_id=l.facility_id and a.unit=l.unit and a.type=l.status
      and x.source_unit_id=r.source_unit_id and x.source_org_id=r.source_org_id end as placement_matches,
   (r.lock_id=l.id and r.combination_verified and r.local_version=l.version and r.applied_fingerprint=r.source_fingerprint) is true as warehouse_code_matches,
   (r.lock_id=l.id and r.export_combination_verified_marker=r.source_marker and r.export_combination_verified_version=l.version) is true as csv_code_matches,
   (r.export_combination_conflict_at is not null
    and (r.export_combination_verified_at is null or r.export_combination_verified_at<=r.export_combination_conflict_at)
    and not (r.lock_id=l.id and r.combination_verified and r.local_version=l.version and r.applied_fingerprint=r.source_fingerprint
       and r.source_snapshot_at>r.export_combination_conflict_at)) is true as csv_conflict_open,
   (r.lock_id=l.id and r.export_combination_conflict_marker=r.source_marker and r.export_combination_conflict_version=l.version) is true as csv_conflict_current,
   r.export_combination_conflict_at
  from public.locks l
  full join current_source r on r.source_lock_id=l.source_lock_id and r.source_org_id=l.source_org_id
  cross join snapshot s
  left join public.facilities f on f.id=l.facility_id
  left join automation.facility_links m on m.source_org_id=r.source_org_id and m.source_facility_id=r.source_facility_id
  left join public.facilities sf on sf.id=m.facility_id
  left join automation.lock_mirror_records previous on previous.source_org_id=l.source_org_id and previous.source_lock_id=l.source_lock_id
  left join public.assignments a on a.lock_id=l.id and a.released_at is null
  left join automation.assignment_links x on x.assignment_id=a.id
  left join automation.lock_mirror_display_evidence d on d.source_org_id=r.source_org_id and d.source_lock_id=r.source_lock_id
   and d.source_facility_id=r.source_facility_id and d.source_unit_id is not distinct from r.source_unit_id
   and d.source_marker=r.source_marker
  left join private.lock_secrets k on k.lock_id=l.id
 ), review as materialized (
  select *,array_remove(array[
   case when status='unclassified' then 'unclassified' end,
   case when complete and lock_id is not null and source_lock_id is null then
    case when was_retained then 'retained_in_msl'
     when local_identity then 'absent_from_cubby'
     else 'local_identity_unverified' end end,
   case when source_lock_id is not null and lock_id is null then 'absent_from_msl' end,
   case when issue in ('serial_identity_conflict','status_assignment_conflict','source_version_conflict') then issue
    when source_lock_id is not null and lock_id is not null then
    case when source_link is distinct from lock_id and coalesce(issue,'') in
      ('','combination_unavailable','combination_unverified','purpose_unverified') then 'identity_link_unverified'
     when issue is not null and issue not in ('combination_unavailable','combination_unverified','purpose_unverified') then 'mirror_review'
     when source_link=lock_id and fingerprint_matches and not coalesce(placement_matches,false) then 'binding_mismatch'
     when source_link=lock_id and fingerprint_matches and display_type is distinct from status and display_type is not null then 'classification_mismatch'
     when version is distinct from local_version or not coalesce(fingerprint_matches,false) then 'mirror_review'
    end end,
   case when source_status='ACTIVE' and not purpose_verified
    and coalesce(issue,'') in ('','combination_unavailable','combination_unverified','purpose_unverified') then
    case display_status when 'Locked' then 'cubby_locked'
     when 'Remove lock' then 'cubby_remove_lock' else 'purpose_unverified' end end,
   case when csv_conflict_open then
    case when csv_conflict_current then 'combination_conflict' else 'prior_combination_conflict' end end,
   case when lock_id is not null and not has_code then 'combination_missing' end
  ],null) as reasons
  from evidence
 ), latest_export_rows as (
  -- An upload that omits a serial cannot supersede earlier evidence for it.
  select distinct on (e.facility_id,j.serial) e.facility_id,j.serial,e.observed_at,j.matched
  from automation.cubby_export_reconciliations e
  cross join lateral (
   select unnest(e.matched_serials) as serial,true as matched
   union all select unnest(e.unmatched_serials),false
  ) j order by e.facility_id,j.serial,e.observed_at desc,e.id desc
 ), latest_successful_export as (
  select facility_id,observed_at,reconciled_at from automation.cubby_export_reconciliations
  where cardinality(matched_serials)>0 order by reconciled_at desc,id desc limit 1
 ), review_counts as (
  select count(*) filter(where status='unclassified') as unclassified,
   count(*) filter(where 'retained_in_msl'=any(reasons)) as retained,
   count(*) filter(where reasons && array['retained_in_msl','absent_from_cubby','absent_from_msl','serial_identity_conflict',
    'status_assignment_conflict','source_version_conflict','binding_mismatch','classification_mismatch','combination_conflict']) as differences,
   count(*) filter(where warehouse_code_matches and has_code and not csv_conflict_open) as warehouse_codes,
   count(*) filter(where csv_code_matches and has_code and not csv_conflict_open) as csv_codes,
   count(*) filter(where (warehouse_code_matches or csv_code_matches) and has_code and not csv_conflict_open) as verified_codes,
   count(*) filter(where lock_id is not null and not has_code) as missing_codes
  from review
 ), review_items as (
  select jsonb_build_object('serial',serial,'sourceId',coalesce(source_lock_id,local_source_id),'facility',coalesce(facility,source_facility),
   'sourceFacility',source_facility,'facilityId',facility_id,'status',status,'unit',unit,'sourceUnit',source_unit,
   'sourceStatus',coalesce(display_status,source_status,case when 'retained_in_msl'=any(reasons) then prior_source_status end),'mirrorIssue',case when 'mirror_review'=any(reasons) then issue end,
   'observedAt',export_combination_conflict_at,'reasons',reasons) as item
  from review where cardinality(reasons)>0
  union all
  select jsonb_build_object('serial',e.serial,'facility',f.name,'facilityId',e.facility_id,
   'observedAt',e.observed_at,'reasons',array['csv_row_unmatched'])
  from latest_export_rows e left join public.facilities f on f.id=e.facility_id where not e.matched
 )
 select jsonb_build_object(
  'asOf',now(),'mode',s.report->'mode','inventory',s.report->'inventoryLocks',
  'matched',case when s.complete then s.report->'coverage'->'placementMatched' end,
  'sourceCount',case when s.complete then s.report->'sourceLocks' end,
  'unclassified',c.unclassified,'retained',case when s.complete then c.retained end,
  'differences',case when s.complete then c.differences end,
  'missingCodes',c.missing_codes,
  'purposeUnverified',case when s.complete then s.report->'purposeUnverified' end,
  'verifiedCodes',case when s.complete then c.verified_codes end,
  'warehouseCodes',case when s.complete then c.warehouse_codes end,
  'csvCodes',case when s.complete then c.csv_codes end,
  'workerState',case when not (s.report->>'enabled')::boolean then 'paused'
    when s.last_error_code is not null then 'failed'
    when s.last_success_at is null then 'unknown'
    when s.last_success_at<now()-interval '5 minutes' then 'delayed' else 'operational' end,
  'lastCheckedAt',s.report->'lastCheckedAt','lastSuccessAt',s.report->'lastSuccessAt',
  'lastErrorCode',s.last_error_code,'lastFullSyncAt',s.finished_at,
  'sourceSnapshotAt',s.last_snapshot_at,'sourceComplete',s.complete,'sourceFresh',s.fresh,
  'capabilities',s.report->'capabilities',
  'latestCsvReconciledAt',e.reconciled_at,'latestCsvObservedAt',e.observed_at,'latestCsvFacility',f.name,
  'legacyCsvEvidenceAt',greatest(
   (select max(export_combination_verified_at) from automation.lock_mirror_records),
   (select max(observed_at) from automation.lock_mirror_display_evidence where source='combo_locks_export')
  ),
  'items',coalesce((select jsonb_agg(item order by item->>'facility',item->>'serial',item->>'sourceId') from review_items),'[]'::jsonb)
 )
 from snapshot s cross join review_counts c
 left join latest_successful_export e on true
 left join public.facilities f on f.id=e.facility_id;
$$;
revoke all on function automation.lock_inventory_reconciliation() from public,anon,authenticated;

create function public.lock_inventory_reconciliation() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.live() or not private.admin() then
  raise exception 'Administrator access required' using errcode='42501';
 end if;
 return automation.lock_inventory_reconciliation();
end $$;
revoke all on function public.lock_inventory_reconciliation() from public,anon;
grant execute on function public.lock_inventory_reconciliation() to authenticated;
