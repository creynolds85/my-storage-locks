begin;
insert into public.facilities(id,name,identifier,source_org_id,source_facility_id)
 values('98600000-0000-0000-0000-000000000001','Combo Export Fixture','COMBO-EXPORT-QA','org_CubbyExportQA','fac_CubbyExportQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id)
 values('org_CubbyExportQA','fac_CubbyExportQA','98600000-0000-0000-0000-000000000001');

do $$
declare fid uuid:='98600000-0000-0000-0000-000000000001';rid uuid; snap timestamptz:=now()-interval '1 minute';
 t jsonb;report jsonb;id uuid;protected bytea;
begin
 insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
  values('org_CubbyExportQA',snap,'combo-export-fixture',2,'{}') returning automation.lock_mirror_runs.id into rid;
 perform automation.lock_mirror_batch(rid,'[
 {"sourceLockId":"lock_CubbyExportQA1","serial":"EXPORTQA1","facilityId":"fac_CubbyExportQA","unitId":"unit_CubbyExportQA","unit":"042","unitMatches":1,"status":"ACTIVE","updatedAt":"2026-11-18 09:00:00","combination":null,"combinationAvailable":false},
 {"sourceLockId":"lock_CubbyExportQA2","serial":"EXPORTQA2","facilityId":"fac_CubbyExportQA","unitId":null,"unit":null,"unitMatches":0,"status":"AVAILABLE","updatedAt":"2026-11-18 09:00:00","combination":"fixture-existing","combinationAvailable":true}]');
 update automation.lock_mirror_runs set state='complete' where automation.lock_mirror_runs.id=rid;
 update automation.lock_mirror_control set last_run_id=rid,last_snapshot_at=snap,owner=null,lease_until=null where mode='mirror';
 select encrypted into strict protected from private.lock_secrets x join public.locks l on l.id=x.lock_id where l.source_lock_id='lock_CubbyExportQA2';
 t:='[{"sourceLockId":"lock_CubbyExportQA1","serial":"EXPORTQA1","unit":"042","label":"On vacant unit","combination":"fixture-0001"},
 {"serial":"EXPORTQA2","unit":null,"label":"Available","combination":"fixture-conflict"}]';
 report:=automation.reconcile_cubby_official_export(fid,snap-interval '1 second',t);
 if not report?'error' then raise exception 'Older file was accepted';end if;
 report:=automation.reconcile_cubby_official_export(fid,now(),t);
 if report->>'combinationsRecovered' is distinct from '1' or report->>'combinationConflicts' is distinct from '1' or report->>'classificationsCorrected' is distinct from '1'
  or report::text like '%fixture-%' then raise exception 'Recovery/report contract failed';end if;
 if not exists(select 1 from public.locks l join private.lock_secrets x on x.lock_id=l.id where l.source_lock_id='lock_CubbyExportQA1'
  and l.status='vacant' and extensions.pgp_sym_decrypt(x.encrypted,(select value from private.encryption_key))='fixture-0001') then raise exception 'Verified record was not recovered';end if;
 if not exists(select 1 from public.locks l join private.lock_secrets x on x.lock_id=l.id where l.source_lock_id='lock_CubbyExportQA2' and x.encrypted=protected) then raise exception 'Existing ciphertext changed';end if;
 if has_function_privilege('anon','public.import_cubby_combo_export(uuid,timestamptz,jsonb)','EXECUTE') then raise exception 'Anonymous import access';end if;
end $$;
rollback;
select 'PASS: stale export rejection, immutable matching, encrypted recovery and preservation' as result;
