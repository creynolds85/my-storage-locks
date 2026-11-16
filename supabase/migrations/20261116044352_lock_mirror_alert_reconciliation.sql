create or replace function automation.lock_mirror_reconcile(run_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare fid uuid;n int;begin
 for fid in select facility_id from automation.facility_links where source_org_id=(select source_org_id from automation.lock_mirror_runs where id=run_id) loop
  perform private.walkthrough_missing(fid);
  select count(*) into n from automation.lock_mirror_records r join automation.facility_links f on f.source_org_id=r.source_org_id and f.source_facility_id=r.source_facility_id where f.facility_id=fid and r.issue is not null and r.issue<>'purpose_unverified';
  if n>0 then
   perform automation.task('lock-mirror:review:'||fid,fid,'assignment_conflict','Cubby lock inventory needs review',n||' lock records could not be verified. Contact an administrator before adding replacement locks.');
  else update public.action_items set state='resolved',resolved_at=now(),updated_at=now() where cause_key='lock-mirror:review:'||fid and state='open';end if;
 end loop;
 -- Reconcile existing source-owned notices even when the cached inspection roster is stale.
 with checked as (
  select a.id,a.state old_state,a.title old_title,a.facility_id,a.unit_label,
   exists(select 1 from automation.lock_mirror_records r join public.locks l on l.id=r.lock_id where r.last_seen_run=run_id and r.source_org_id=fl.source_org_id and r.source_facility_id=fl.source_facility_id and r.source_unit_id=split_part(a.cause_key,':',4) and r.applied_fingerprint=r.source_fingerprint and r.local_version=l.version and r.purpose_verified and l.status=split_part(a.cause_key,':',5) and l.unit=a.unit_label) as verified
  from public.action_items a join automation.facility_links fl on fl.facility_id=a.facility_id
  where a.state='open' and a.kind='walkthrough_missing' and a.cause_key like 'walkthrough:missing:'||a.facility_id||':%' and fl.source_org_id=(select source_org_id from automation.lock_mirror_runs where id=run_id)
 ), corrected as (
  update public.action_items a set state=case when c.verified then 'resolved' else 'open' end,
   title=case when c.verified then a.title else 'Verify Cubby lock assignment' end,
   detail=case when c.verified then a.detail else 'Verify the latest Cubby lock assignment before adding a replacement lock. Reporting may be delayed; this is not proof that a physical lock is absent.' end,
   lock_type=case when c.verified then a.lock_type end,resolved_at=case when c.verified then now() end,updated_at=now()
  from checked c where a.id=c.id and (c.verified or a.title<>'Verify Cubby lock assignment')
  returning a.id,a.facility_id,a.state,c.old_state,c.old_title
 ) insert into public.activity(facility_id,action,before_values,after_values)
 select facility_id,'cubby_mirror_alert_reconciled',jsonb_build_object('actionItemId',id,'state',old_state,'title',old_title),jsonb_build_object('actionItemId',id,'state',state,'reason','Source inventory reconciliation; no manager observation dismissed') from corrected;
 -- Only obsolete machine-generated notification exceptions; never manager observations.
 with matched as (
 select a.id,s.lease_id,s.unit_label,f.facility_id from public.action_items a join automation.facility_links f on f.facility_id=a.facility_id join automation.operational_snapshots s on s.source_org_id=f.source_org_id and s.source_facility_id=f.source_facility_id
 cross join (values('new_rental'),('overlock_clearance')) k(kind) cross join (values('lease_not_current'),('access_restriction'),('assignment_changed'),('missing_assignment'),('consent_unverified')) reason(code)
 where a.state='open' and a.kind in ('assignment_conflict','missing_assignment') and a.notification_id is null
 and a.cause_key='event:'||encode(extensions.digest(s.lease_id||':'||k.kind||':'||coalesce(s.facts->>'episodeId','')||':'||reason.code,'sha256'),'hex')
 and exists(select 1 from public.activity h join public.locks l on l.id=h.lock_id join automation.lock_mirror_records r on r.lock_id=l.id where h.facility_id=f.facility_id and h.action in ('cubby_mirror_inventory','cubby_mirror_combination_and_inventory') and h.created_at>=(select created_at from automation.lock_mirror_runs where id=run_id) and h.before_values->>'unit'=s.unit_label and (h.after_values->>'unit' is distinct from s.unit_label or h.after_values->>'status' in ('tenant_held','available','missing','damaged')) and r.last_seen_run=run_id and r.applied_fingerprint=r.source_fingerprint and l.version=r.local_version)
 and not exists(select 1 from public.locks l join public.assignments x on x.lock_id=l.id and x.released_at is null where l.facility_id=f.facility_id and l.unit=s.unit_label and l.status in ('vacant','overlock','auction','unclassified'))
 and not exists(select 1 from automation.notification_outbox o where o.lease_id=s.lease_id and o.state in ('dispatching','unknown','submitted'))
 ), corrected as(update public.action_items a set state='resolved',resolved_at=now(),updated_at=now(),unit_label=m.unit_label from matched m where a.id=m.id returning a.id,a.facility_id,a.unit_label)
 insert into public.activity(facility_id,action,after_values) select facility_id,'cubby_mirror_obsolete_notification_resolved',jsonb_build_object('actionItemId',id,'unit',unit_label,'reason','Source-confirmed physical binding changed; no access authorization or SMS issued') from corrected;
end $$;
