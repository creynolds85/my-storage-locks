begin;
insert into public.facilities(id,name,identifier,source_org_id,source_facility_id) values('98000000-0000-0000-0000-000000000001','Metadata Fixture','MIRROR-META-QA','org_MetaQA','fac_MetaQA');
insert into automation.facility_links(source_org_id,source_facility_id,facility_id) values('org_MetaQA','fac_MetaQA','98000000-0000-0000-0000-000000000001');
insert into public.locks(id,serial,color,facility_id,status,source_org_id,source_lock_id,source_updated_at,imported_at) values('98000000-0000-0000-0000-000000000002','METAQA','Unknown','98000000-0000-0000-0000-000000000001','available','org_MetaQA','lock_MetaQA','2026-11-01T00:00:00Z','2026-11-05T00:00:00Z');
insert into private.lock_secrets values('98000000-0000-0000-0000-000000000002',extensions.pgp_sym_encrypt('0042',(select value from private.encryption_key)));
update automation.lock_mirror_control set enabled=true where id;
insert into public.action_items(facility_id,kind,cause_key,title,unit_label,lock_type) values('98000000-0000-0000-0000-000000000001','walkthrough_missing','walkthrough:missing:98000000-0000-0000-0000-000000000001:unit_MetaQA:vacant','Add Vacant Lock','0008','vacant');
insert into public.action_items(facility_id,kind,cause_key,title) values('98000000-0000-0000-0000-000000000001','walkthrough_issue','mirror_meta_physical_damage','Door/Latch Damage');
do $$declare owner_id uuid:='98000000-0000-0000-0000-000000000099';r jsonb;rid uuid;j jsonb;step int;c bytea;begin
 select encrypted into c from private.lock_secrets where lock_id='98000000-0000-0000-0000-000000000002';
 for step in 1..1 loop
  j:=jsonb_build_object('sourceLockId','lock_MetaQA','serial','METAQA','facilityId','fac_MetaQA','unitId','unit_MetaQA','unit','0008','unitMatches',1,'status','ACTIVE','updatedAt','2026-11-02 00:00:00','createdAt',null,'needsMaintenance',false,'customLocation',null,'combination',case when step=1 then null when step=2 then '00-AB' else 'REJECTED' end,'combinationAvailable',step<>1);
  perform automation.lock_mirror_worker('lock_mirror_claim',jsonb_build_object('owner',owner_id,'force',true));
  r:=automation.lock_mirror_worker('lock_mirror_start',jsonb_build_object('owner',owner_id,'orgId','org_MetaQA','snapshotAt',now()-interval '1 minute'+step*interval '1 second','key','meta'||step,'total',1,'capabilities',jsonb_build_object('combinations',step<>1)));rid:=(r->>'id')::uuid;
  r:=automation.lock_mirror_worker('lock_mirror_batch',jsonb_build_object('owner',owner_id,'runId',rid,'records',jsonb_build_array(j)));if r->>'saved' is distinct from 'true' then raise exception 'FAIL metadata batch';end if;
  r:=automation.lock_mirror_worker('lock_mirror_finish',jsonb_build_object('owner',owner_id,'runId',rid));if r->>'mode' is distinct from 'mirror' then raise exception 'FAIL metadata finish';end if;
  if step=1 then
   if (select unit from public.locks where id='98000000-0000-0000-0000-000000000002')<>'0008' then raise exception 'FAIL metadata assignment';end if;
   if c is distinct from(select encrypted from private.lock_secrets where lock_id='98000000-0000-0000-0000-000000000002') then raise exception 'FAIL unavailable combination overwritten';end if;
   if (select combination_verified from automation.lock_mirror_records where source_org_id='org_MetaQA') then raise exception 'FAIL unverified code claimed verified';end if;
  elsif step=2 then
   if (select extensions.pgp_sym_decrypt(encrypted,(select value from private.encryption_key)) from private.lock_secrets where lock_id='98000000-0000-0000-0000-000000000002')<>'00-AB' then raise exception 'FAIL first verified combination permission restoration';end if;
  else
   if (select issue from automation.lock_mirror_records where source_org_id='org_MetaQA')<>'source_version_conflict' then raise exception 'FAIL known same-version combination conflict';end if;
  end if;
 end loop;
 if not exists(select 1 from public.action_items where cause_key='walkthrough:missing:98000000-0000-0000-0000-000000000001:unit_MetaQA:vacant' and title='Verify Cubby lock assignment' and lock_type is null and state='open') then raise exception 'FAIL stale-roster false physical-missing claim';end if;
 if not exists(select 1 from public.action_items where cause_key='mirror_meta_physical_damage' and state='open') then raise exception 'FAIL manager physical issue dismissed';end if;
end $$;
rollback;
select 'PASS: stale-roster Add Lock claim replaced with source review; manager physical issue retained; all fixtures rolled back' as result;
