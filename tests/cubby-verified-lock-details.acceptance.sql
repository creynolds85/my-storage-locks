begin;
insert into public.facilities(id,name,identifier,source_org_id,source_facility_id)
 values('98400000-0000-0000-0000-000000000001','Verified Detail Fixture','VERIFIED-DETAIL-QA','org_DetailQA','fac_DetailQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id)
 values('org_DetailQA','fac_DetailQA','98400000-0000-0000-0000-000000000001');
insert into public.locks(id,serial,color,facility_id,source_org_id,source_lock_id,source_updated_at)
 values('98400000-0000-0000-0000-000000000002','DETAILQA','Green','98400000-0000-0000-0000-000000000001','org_DetailQA','lock_DetailQA','2026-11-01');
insert into private.lock_secrets(lock_id,encrypted) values('98400000-0000-0000-0000-000000000002',decode('21234567','hex'));

do $$
declare
 fid uuid:='98400000-0000-0000-0000-000000000001';
 lid uuid:='98400000-0000-0000-0000-000000000002';
 rid uuid;
 r jsonb:='{"sourceLockId":"lock_DetailQA","serial":"DETAILQA","facilityId":"fac_DetailQA","unitId":"unit_DetailQA","unit":"42","unitMatches":1,"status":"ACTIVE","updatedAt":"2026-11-02 00:00:00","combination":null,"combinationAvailable":false}';
 v integer;
 step integer;
begin
 for step in 1..4 loop
  if step=3 then
   update public.assignments set released_at=now() where lock_id=lid and released_at is null;
   update public.locks set status='available',unit=null,color='Black',version=version+1 where id=lid returning version into v;
   insert into public.activity(lock_id,facility_id,action,after_values) values(lid,fid,'release',jsonb_build_object('version',v));
   if not private.walkthrough_cubby_assignment_conflict(fid,'unit_DetailQA','42') then raise exception 'FAIL genuine missing placement hidden';end if;
  elsif step=4 then
   update public.locks set version=version+1 where id=lid returning version into v;
   insert into public.activity(lock_id,facility_id,action,after_values) values(lid,fid,'change_combination',jsonb_build_object('version',v));
  end if;
  insert into automation.lock_mirror_runs(source_org_id,snapshot_at,snapshot_key,source_count,capabilities)
  values('org_DetailQA',clock_timestamp(),'detail'||step,1,jsonb_build_object('physicalLockColorColumn',case when step=2 then 'physical_color'::text end))
  returning id into rid;
  perform automation.lock_mirror_batch(rid, jsonb_build_array(r||jsonb_build_object('physicalColor',case when step=2 then 'Red' else 'Unknown' end)));
  if step<4 then
   if not exists(select 1 from public.locks where id=lid and unit='42' and status='unclassified'
     and color=case step when 1 then 'Green' when 2 then 'Red' else 'Black' end)
   then raise exception 'FAIL verified color or assignment at step %',step;end if;
   if private.walkthrough_cubby_assignment_conflict(fid,'unit_DetailQA','42') then raise exception 'FAIL routine purpose uncertainty flagged';end if;
   if private.walkthrough_expected_for_display(fid,'unit_DetailQA','{"label":"42","missing":false,"assignmentReview":true,"sourceReview":true}')->>'sourceReview'='true'
    then raise exception 'FAIL stale display flag';end if;
  elsif not exists(select 1 from automation.lock_mirror_records where lock_id=lid and issue='local_change_after_sync')
     or not private.walkthrough_cubby_assignment_conflict(fid,'unit_DetailQA','42') then
   raise exception 'FAIL local combination change should remain a conflict';
  end if;
  if (select encrypted from private.lock_secrets where lock_id=lid)<>decode('21234567','hex') then
   raise exception 'FAIL existing encrypted combination changed';
  end if;
 end loop;
end $$;
rollback;
select 'PASS: verified color, safe Cubby placement copy, encrypted code preservation and warning rules' as result;
