begin;

insert into public.facilities(id,name,identifier,source_org_id,source_facility_id)
 values('98500000-0000-0000-0000-000000000001','Combo Labels Fixture','COMBO-LABEL-QA','org_ComboLabelQA','fac_ComboLabelQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id)
 values('org_ComboLabelQA','fac_ComboLabelQA','98500000-0000-0000-0000-000000000001');

do $$
<<cubby_test>>
declare
 row_json jsonb:='{"sourceLockId":"lock_ComboLabelQA","serial":"COMBOLABELQA","facilityId":"fac_ComboLabelQA","unitId":"unit_ComboLabelQA","unit":"042","unitMatches":1,"status":"ACTIVE","updatedAt":"2026-11-18 09:00:00","combination":null,"combinationAvailable":false}';
 step int;
 run uuid;
 lock_id uuid;
 original_assignment uuid;
 actual_assignment uuid;
 expected text;
 labels text[]:=array['Locked','On vacant unit','Overlocked','Locked for auction','Locked','On vacant unit'];
 targets text[]:=array['unclassified','vacant','overlock','auction','auction','auction'];
 snapshot_base timestamptz:=clock_timestamp();
begin
 if has_function_privilege('authenticated','automation.reconcile_cubby_lock_display(text,timestamptz,jsonb)','EXECUTE')
  or has_function_privilege('anon','automation.reconcile_cubby_lock_display(text,timestamptz,jsonb)','EXECUTE') then
  raise exception 'Export reconciliation must be restricted';
 end if;
 for step in 1..6 loop
  insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
  values('org_ComboLabelQA',snapshot_base+step*interval '1 second','combo-label-fixture-'||step,1,
   '{"explicitPurpose":true,"lockDisplayStatusColumn":"display_status"}') returning id into run;
  perform automation.lock_mirror_batch(run,jsonb_build_array(row_json
   || jsonb_build_object('sourceDisplayStatus',labels[step],'updatedAt',case when step=6 then '2026-11-17 09:00:00' else '2026-11-18 09:00:00' end)));
  select l.id,l.status,a.id into strict lock_id,expected,actual_assignment
   from public.locks l join public.assignments a on a.lock_id=l.id and a.released_at is null
   where l.source_org_id='org_ComboLabelQA' and l.source_lock_id='lock_ComboLabelQA';
  if expected<>targets[step] then raise exception 'Wrong Combo Locks classification for step %: %',step,expected;end if;
  if step=1 then
   original_assignment:=actual_assignment;
   insert into private.lock_secrets(lock_id,encrypted) values(cubby_test.lock_id,decode('7634ab0c','hex'));
  elsif actual_assignment<>original_assignment
    or not exists(select 1 from private.lock_secrets s where s.lock_id=cubby_test.lock_id and s.encrypted=decode('7634ab0c','hex')) then
   raise exception 'Classification changed an assignment identity or encrypted combination';
  end if;
 end loop;
 if not exists(select 1 from automation.lock_mirror_records r where r.lock_id=cubby_test.lock_id and r.issue='older_source_record' and not r.purpose_verified) then
  raise exception 'Generic or stale input was incorrectly verified';
 end if;
end $$;

rollback;
select 'PASS: exact Combo Locks labels, generic label, stale markers, assignment identity, encryption and permissions' as result;
