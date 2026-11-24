begin;
insert into public.facilities(id,name,identifier,source_org_id,source_facility_id)
 values('98700000-0000-0000-0000-000000000001','Inventory Review Fixture','INVENTORY-REVIEW-QA','org_InventoryReviewQA','fac_InventoryReviewQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id)
 values('org_InventoryReviewQA','fac_InventoryReviewQA','98700000-0000-0000-0000-000000000001');

do $$
declare
 fid uuid:='98700000-0000-0000-0000-000000000001';
 rid uuid;
 older uuid;
 snap timestamptz:=now()-interval '2 minutes';
 report jsonb;
 result jsonb;
begin
 insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
 values('org_InventoryReviewQA',snap-interval '1 hour','review-previous',1,'{}') returning id into older;
 perform automation.lock_mirror_batch(older,'[
  {"sourceLockId":"lock_ReviewRetained","serial":"RETAINED1","facilityId":"fac_InventoryReviewQA","unitMatches":0,
   "status":"MISSING","updatedAt":"2026-11-23 09:00:00","combination":"fixture-retained","combinationAvailable":true}
 ]');
 insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
 values('org_InventoryReviewQA',snap,'review-latest',5,'{"combinations":false,"explicitPurpose":false}') returning id into rid;
 perform automation.lock_mirror_batch(rid,'[
  {"sourceLockId":"lock_ReviewNoCode","serial":"NOCODE1","facilityId":"fac_InventoryReviewQA","unitId":"unit_ReviewQA","unit":"042","unitMatches":1,
   "status":"ACTIVE","updatedAt":"2026-11-24 09:00:00","combination":null,"combinationAvailable":false},
  {"sourceLockId":"lock_ReviewUnknown","serial":"UNKNOWN1","facilityId":"fac_InventoryReviewQA","unitMatches":0,
   "status":"AVAILABLE","updatedAt":"2026-11-24 09:00:00","combination":"fixture-unverified","combinationAvailable":true},
  {"sourceLockId":"lock_ReviewCsv","serial":"CSV1","facilityId":"fac_InventoryReviewQA","unitMatches":0,
   "status":"AVAILABLE","updatedAt":"2026-11-24 09:00:00","combination":"fixture-stored","combinationAvailable":true},
  {"sourceLockId":"lock_ReviewSourceOnly","serial":"SOURCE1","facilityId":"fac_UnmappedQA","unitMatches":0,
   "status":"AVAILABLE","updatedAt":"2026-11-24 09:00:00","combination":null,"combinationAvailable":false},
  {"sourceLockId":"lock_ReviewPlacement","serial":"PLACE1","facilityId":"fac_InventoryReviewQA","unitId":"unit_ReviewQA2","unit":"043","unitMatches":1,
   "status":"ACTIVE","updatedAt":"2026-11-24 09:00:00","combination":"fixture-other","combinationAvailable":true}
 ]');
 update automation.lock_mirror_records set issue='source_record_missing' where last_seen_run=older;
 update automation.lock_mirror_records set combination_verified=false,issue='combination_unavailable' where source_lock_id='lock_ReviewUnknown';
 update automation.lock_mirror_runs set state='complete',finished_at=now()-interval '1 minute' where id=rid;
 update automation.lock_mirror_control set mode='mirror',enabled=true,last_run_id=rid,last_snapshot_at=snap,
  last_success_at=now(),last_checked_at=now(),last_error_code=null,owner=null,lease_until=null where id;

 report:=automation.lock_inventory_reconciliation();
 if report->>'matched' is distinct from '4' or report->>'unclassified' is distinct from '2'
  or report->>'retained' is distinct from '1' or report->>'differences' is distinct from '2'
  or report->>'missingCodes' is distinct from '1' or report->>'workerState' is distinct from 'operational'
  or report->>'sourceFresh' is distinct from 'true' or report->>'latestCsvReconciledAt' is not null then
  raise exception 'Initial reconciliation counts or telemetry failed';
 end if;
 if not report->'items' @> '[{"sourceId":"lock_ReviewSourceOnly","reasons":["absent_from_msl"]},
  {"serial":"RETAINED1","reasons":["retained_in_msl"]},{"serial":"NOCODE1","reasons":["unclassified","combination_missing"]}]'
  or report->'items' @> '[{"serial":"UNKNOWN1"}]' then
  raise exception 'Missing evidence was confused with a discrepancy or a review record was omitted';
 end if;

 result:=automation.reconcile_cubby_official_export(fid,snap-interval '1 second',
  '[{"serial":"CSV1","unit":null,"label":"Available","combination":"fixture-stale"}]');
 if not result?'error' or exists(select 1 from automation.cubby_export_reconciliations) then
  raise exception 'Rejected CSV created a receipt';
 end if;
 result:=automation.reconcile_cubby_official_export(fid,snap+interval '1 second',
  '[{"serial":"CSV1","unit":null,"label":"Available","combination":"fixture-different"},
    {"serial":"UNMATCHED1","unit":null,"label":"Available","combination":"fixture-unmatched"}]');
 report:=automation.lock_inventory_reconciliation();
 if result->>'combinationConflicts' is distinct from '1' or report->>'verifiedCodes' is distinct from '1'
  or report->>'differences' is distinct from '3' or report->>'latestCsvReconciledAt' is null
  or not report->'items' @> '[{"serial":"CSV1","reasons":["combination_conflict"]},{"serial":"UNMATCHED1","reasons":["csv_row_unmatched"]}]'
  or report::text like '%fixture-%' then raise exception 'Safe CSV discrepancy reporting failed';end if;

 result:=automation.reconcile_cubby_official_export(fid,snap+interval '2 seconds',
  '[{"serial":"CSV1","unit":null,"label":"Available","combination":"fixture-stored"}]');
 report:=automation.lock_inventory_reconciliation();
 if result->>'combinationsMatched' is distinct from '1' or report->>'verifiedCodes' is distinct from '2'
  or report->>'csvCodes' is distinct from '1' or report->>'differences' is distinct from '2'
  or not report->'items' @> '[{"serial":"UNMATCHED1","reasons":["csv_row_unmatched"]}]' then
  raise exception 'Newer corroboration did not supersede prior conflict or verification was counted twice';
 end if;

 -- Simulate exact source-backed classification and placement disagreements.
 insert into automation.lock_mirror_display_evidence
 (source_org_id,source_lock_id,source_facility_id,source_unit_id,source_marker,display_status,observed_at,source)
 select source_org_id,source_lock_id,source_facility_id,source_unit_id,source_marker,'Overlocked',now(),'combo_locks_export'
 from automation.lock_mirror_records where source_lock_id='lock_ReviewNoCode';
 update public.assignments set unit='093' where lock_id=(select id from public.locks where serial='PLACE1');
 report:=automation.lock_inventory_reconciliation();
 if report->>'matched' is distinct from '3' or not report->'items' @> '[{"serial":"NOCODE1","reasons":["classification_mismatch"]},
  {"serial":"PLACE1","unit":"043","sourceUnit":"043","reasons":["binding_mismatch"]}]' then
  raise exception 'Source-backed classification and placement differences were not shown';
 end if;
 update automation.lock_mirror_control set last_snapshot_at=now()-interval '100 minutes' where id;
 report:=automation.lock_inventory_reconciliation();
 if report->>'workerState' is distinct from 'operational' or report->>'sourceFresh' is distinct from 'false' then
  raise exception 'Worker success was treated as fresh source data';
 end if;
 update automation.lock_mirror_records set last_seen_run=gen_random_uuid() where source_lock_id='lock_ReviewCsv';
 report:=automation.lock_inventory_reconciliation();
 if report->>'sourceComplete' is distinct from 'false' or report->>'matched' is not null or report->>'differences' is not null
  or report->'items' @> '[{"serial":"CSV1","reasons":["absent_from_cubby"]}]' then
  raise exception 'A partial mirror run reported a false absence';
 end if;
 if has_function_privilege('anon','public.lock_inventory_reconciliation()','EXECUTE')
  or has_function_privilege('authenticated','automation.lock_inventory_reconciliation()','EXECUTE')
  or has_table_privilege('authenticated','automation.cubby_export_reconciliations','SELECT') then
  raise exception 'Review permissions grant direct or anonymous access';
 end if;
end $$;

insert into auth.users(id,email) values('98700000-0000-0000-0000-000000000002','inventory-review@example.invalid');
insert into public.profiles(id,email,name,role)
 values('98700000-0000-0000-0000-000000000002','inventory-review@example.invalid','Inventory Review Fixture','employee');
insert into auth.sessions(id,user_id,created_at)
 values('98700000-0000-0000-0000-000000000003','98700000-0000-0000-0000-000000000002',now());
select set_config('request.jwt.claims','{"sub":"98700000-0000-0000-0000-000000000002","session_id":"98700000-0000-0000-0000-000000000003"}',true);
set local role authenticated;
do $$begin
 begin
  perform public.lock_inventory_reconciliation();
  raise exception 'Employee accessed the administrator RPC';
 exception when insufficient_privilege then null;
 end;
end $$;
reset role;
update public.profiles set role='admin' where id='98700000-0000-0000-0000-000000000002';
set local role authenticated;
do $$begin
 if public.lock_inventory_reconciliation()->>'inventory' is null then raise exception 'Administrator could not read the report';end if;
end $$;
reset role;
update auth.sessions set created_at=now()-interval '31 minutes' where id='98700000-0000-0000-0000-000000000003';
set local role authenticated;
do $$begin
 begin
  perform public.lock_inventory_reconciliation();
  raise exception 'Expired administrator session accessed the RPC';
 exception when insufficient_privilege then null;
 end;
end $$;
rollback;
select 'PASS: inventory reconciliation counts, evidence coverage, CSV receipts, and administrator access' as result;
