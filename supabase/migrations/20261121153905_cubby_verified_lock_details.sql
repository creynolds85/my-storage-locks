-- Keep the existing source identity, freshness, combination and notification safeguards.
-- An exact source placement can supersede an auditable local inventory-only edit.
create function automation.lock_mirror_inventory_edits_only(lid uuid, from_version integer, to_version integer)
returns boolean language sql stable security invoker set search_path='' as $$
 select to_version>from_version and count(*)=to_version-from_version
  and count(distinct revision)=to_version-from_version
  and coalesce(bool_and(action in ('assign','release','status','classify','edit')),false)
 from (
  select action,case when jsonb_typeof(after_values->'version')='number'
   then (after_values->'version')::integer end as revision
  from public.activity where lock_id=lid
 ) h
 where revision>from_version and revision<=to_version
$$;
revoke all on function automation.lock_mirror_inventory_edits_only(uuid,integer,integer) from public,anon,authenticated;

do $migration$
declare
 definition text:=pg_get_functiondef('automation.lock_mirror_batch(uuid,jsonb)'::regprocedure);
 old_guard text:=$old$if s.lock_id is not null and s.local_version is distinct from l.version then why:='local_change_after_sync';raise exception 'Review required';end if;$old$;
begin
 if strpos(definition,old_guard)=0 or strpos(definition,'source_metadata_fingerprint')=0 or
    strpos(definition,'if fp=s.applied_fingerprint')=0 or strpos(definition,'elsif changed then')=0 then
  raise exception 'Lock mirror body changed; review this migration';
 end if;
 definition:=replace(definition,'old_facility uuid;', 'old_facility uuid;source_color text;prior_color text;');
 definition:=replace(definition,$old$marker:=(j->>'updatedAt')::timestamp;$old$,$new$marker:=(j->>'updatedAt')::timestamp;
   source_color:=case when run.capabilities->>'physicalLockColorColumn' in ('physical_color','lock_color')
    and j->>'physicalColor' in ('Red','Black','Green','Other') then j->>'physicalColor' end;
   j:=j-'physicalColor';$new$);
 definition:=replace(definition,old_guard,$new$if s.lock_id is not null and s.local_version is distinct from l.version and not coalesce((
    s.lock_id=l.id and l.facility_id=fid and
    (not coalesce(combo_valid,false) or exists (
      select 1 from private.lock_secrets x where x.lock_id=l.id and
       extensions.pgp_sym_decrypt(x.encrypted,(select value from private.encryption_key))=j->>'combination'
    )) and automation.lock_mirror_inventory_edits_only(l.id,s.local_version,l.version)
   ),false) then why:='local_change_after_sync';raise exception 'Review required';end if;
   prior_color:=l.color;$new$);
 definition:=replace(definition,$old$and l.unit is not distinct from j->>'unit' then$old$,$new$and l.unit is not distinct from j->>'unit' and (source_color is null or l.color=source_color) then$new$);
 definition:=replace(definition,$old$values(j->>'serial','Unknown',fid$old$,$new$values(j->>'serial',coalesce(source_color,'Unknown'),fid$new$);
 definition:=replace(definition,$old$elsif changed then
    update public.locks set facility_id=fid,status=typ,unit=j->>'unit',version=version+1$old$,$new$elsif changed or (source_color is not null and source_color is distinct from l.color) then
    update public.locks set facility_id=fid,status=typ,unit=j->>'unit',color=coalesce(source_color,color),version=version+1$new$);
 definition:=replace(definition,$old$if changed then insert into public.activity$old$,$new$if prior_color is not null and prior_color is distinct from l.color then
    insert into public.activity(lock_id,facility_id,action,before_values,after_values)
    values(l.id,fid,'cubby_mirror_physical_color',jsonb_build_object('color',prior_color),jsonb_build_object('color',l.color,'sourceSnapshotAt',run.snapshot_at));
   end if;
   if changed then insert into public.activity$new$);
 if strpos(definition,'coalesce(source_color,color)')=0 or strpos(definition,'cubby_mirror_physical_color')=0 then raise exception 'Lock color integration point changed';end if;
 execute definition;
end
$migration$;

-- Calculate operational warnings at read time. Stored inspection snapshots,
-- acknowledgements and independently reported issues are deliberately untouched.
create function private.walkthrough_cubby_assignment_conflict(fid uuid, source_unit text, expected_label text)
returns boolean language sql stable security invoker set search_path='' as $$
 select exists (
  select 1 from automation.facility_links f join automation.lock_mirror_records r
    on r.source_org_id=f.source_org_id and r.source_facility_id=f.source_facility_id
  left join public.locks l on l.id=r.lock_id
  left join public.assignments a on a.lock_id=l.id and a.released_at is null
  left join automation.assignment_links x on x.assignment_id=a.id
  where f.facility_id=fid and r.source_unit_id=source_unit
    and r.source_status in ('ACTIVE','IN_TENANT')
    and (
     r.issue not in ('purpose_unverified','combination_unavailable','combination_unverified')
     or (l.version is distinct from r.local_version and not coalesce(automation.lock_mirror_inventory_edits_only(l.id,r.local_version,l.version),false))
     or r.unit_label is distinct from expected_label
     or l.facility_id is distinct from f.facility_id or l.unit is distinct from r.unit_label
     or a.facility_id is distinct from f.facility_id or a.unit is distinct from r.unit_label
     or a.type is distinct from l.status or x.source_unit_id is distinct from r.source_unit_id
     or x.source_org_id is distinct from r.source_org_id
    )
 )
$$;
revoke all on function private.walkthrough_cubby_assignment_conflict(uuid,text,text) from public,anon,authenticated;

create function private.walkthrough_expected_for_display(fid uuid, source_unit text, expected jsonb)
returns jsonb language sql stable security invoker set search_path='' as $$
 select case when c.conflict then expected||'{"missing":false,"assignmentReview":true,"sourceReview":true}'::jsonb
  else (expected-'assignmentReview'-'sourceReview')||'{"missing":false}'::jsonb end
 from (select private.walkthrough_cubby_assignment_conflict(fid,source_unit,expected->>'label') as conflict) c
$$;
revoke all on function private.walkthrough_expected_for_display(uuid,text,jsonb) from public,anon,authenticated;

do $migration$
declare definition text:=pg_get_functiondef('private.walkthrough_entry_json(uuid)'::regprocedure);
begin
 if strpos(definition,'''expected'', e.expected')=0 and strpos(definition,'''expected'',e.expected')=0 then
  raise exception 'Walk-Through entry response changed; review this migration';
 end if;
 definition:=replace(replace(definition,'''expected'', e.expected','''expected'',e.expected'),'''expected'',e.expected',
  '''expected'',case when w.status=''in_progress'' and exists(select 1 from automation.lock_mirror_control where id and mode=''mirror'') then private.walkthrough_expected_for_display(w.facility_id,e.unit_source_id,e.expected) else e.expected end');
 definition:=replace(definition,'from private.walkthrough_entries e left join','from private.walkthrough_entries e join private.walkthrough_weeks w on w.id=e.week_id left join');
 if strpos(definition,'join private.walkthrough_weeks w')=0 then raise exception 'Walk-Through session join changed';end if;
 execute definition;
end
$migration$;
