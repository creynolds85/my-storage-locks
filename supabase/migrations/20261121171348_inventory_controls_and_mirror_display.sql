-- Keep legacy unset values readable. New operator input accepts only approved colors.
alter table public.locks drop constraint locks_color_check,
 add constraint locks_color_check check(color in ('Green','Red','Blue','Black','Unknown','Other'));

do $migration$
declare d text:=pg_get_functiondef('private.mutate_lock(jsonb)'::regprocedure);
 create_anchor text:='insert into public.locks(serial,color,facility_id,notes) values(s,p->>''color'',fid,';
 edit_anchor text:='update public.locks set color=p->>''color'',notes=';
begin
 if strpos(d,create_anchor)=0 or strpos(d,edit_anchor)=0 then raise exception 'Lock color integration point changed';end if;
 d:=replace(d,create_anchor,'if p ? ''color'' and coalesce(p->>''color'','''') not in (''Green'',''Red'',''Blue'',''Black'') then raise exception ''Choose Green, Red, Blue, or Black.'' using errcode=''22023'';end if; '||
  'insert into public.locks(serial,color,facility_id,notes) values(s,coalesce(p->>''color'',''Unknown''),fid,');
 d:=replace(d,edit_anchor,'if p ? ''color'' and coalesce(p->>''color'','''') not in (''Green'',''Red'',''Blue'',''Black'') then raise exception ''Choose Green, Red, Blue, or Black.'' using errcode=''22023'';end if; '||
  'update public.locks set color=coalesce(p->>''color'',l.color),notes=');
 execute d;
 d:=pg_get_functiondef('automation.lock_mirror_batch(uuid,jsonb)'::regprocedure);
 if strpos(d,$old$j->>'physicalColor' in ('Red','Black','Green','Other')$old$)=0 then raise exception 'Mirror color integration point changed';end if;
 execute replace(d,$old$j->>'physicalColor' in ('Red','Black','Green','Other')$old$,$new$j->>'physicalColor' in ('Red','Black','Green','Blue')$new$);
end
$migration$;

-- The same RPC sorts before pagination and retains existing filters and row security.
do $migration$
declare d text:=pg_get_functiondef('public.inventory_listing(text,uuid,text[],text,integer,integer,boolean)'::regprocedure);
 sorts text:=$old$p_sort not in ('serial','facility_serial','updated_at','created_at')$old$;
 order_anchor text:=$old$case when p_sort='facility_serial' then facility_name end collate public.inventory_natural,$old$;
begin
 if strpos(d,sorts)=0 or strpos(d,order_anchor)=0 then raise exception 'Inventory sort integration point changed';end if;
 d:=replace(d,sorts,$new$coalesce(p_sort,'') not in ('serial','serial_desc','facility_serial','facility_desc','updated_at','created_at',
 'status_asc','status_desc','unit_asc','unit_desc','color_asc','color_desc')$new$);
 d:=replace(d,'end as serial_prefix','end as serial_prefix,
   array_position(array[''available'',''vacant'',''overlock'',''auction'',''tenant_held'',''maintenance'',''missing'',''damaged'',''retired'',''unclassified''],l.status) as status_rank');
 d:=replace(d,order_anchor,order_anchor||$new$
   case when p_sort='facility_desc' then facility_name end collate public.inventory_natural desc nulls last,
   case when p_sort='unit_asc' then nullif(unit,'') end collate public.inventory_natural asc nulls last,
   case when p_sort='unit_desc' then nullif(unit,'') end collate public.inventory_natural desc nulls last,
   case when p_sort='status_asc' then status_rank end asc nulls last,
   case when p_sort='status_desc' then status_rank end desc nulls last,
   case when p_sort='color_asc' and color in ('Green','Red','Blue','Black') then color end asc nulls last,
   case when p_sort='color_desc' and color in ('Green','Red','Blue','Black') then color end desc nulls last,
   case when p_sort='serial_desc' then serial_kind end desc,
   case when p_sort='serial_desc' then serial_prefix end collate "C" desc,
   case when p_sort='serial_desc' then serial end collate public.inventory_natural desc,
   case when p_sort='serial_desc' then lower(serial) end collate "C" desc,
   case when p_sort='serial_desc' then serial end collate "C" desc,
 $new$);
 d:=replace(d,$old$-'created_at'-'updated_at'$old$,$new$-'created_at'-'updated_at'-'status_rank'$new$);
 execute d;
end
$migration$;

-- Reconciliation findings stay in the backend. Only a fresh, mapped unit with
-- no recorded binding gets a neutral assignment notice in the manager response.
create or replace function private.walkthrough_expected_for_display(fid uuid, source_unit text, expected jsonb)
returns jsonb language sql stable security invoker set search_path='' as $$
 select (expected-'assignmentReview'-'sourceReview')||jsonb_build_object('mirrorMode',true,'missing',
  coalesce(expected->>'requiredType','')<>'' and
  coalesce(jsonb_array_length(expected->'locks'),0)=0 and exists(
   select 1 from automation.lock_mirror_control c join automation.unit_links u
    on u.facility_id=fid and u.source_unit_id=source_unit and u.label=expected->>'label'
   join automation.lock_mirror_runs run on run.id=c.last_run_id and run.source_org_id=u.source_org_id
   where c.id and c.last_snapshot_at>=now()-interval '95 minutes' and run.state='complete'
    and not exists(select 1 from automation.lock_mirror_records r where r.last_seen_run=run.id
     and r.source_org_id=u.source_org_id and r.source_facility_id=u.source_facility_id and r.source_unit_id=u.source_unit_id
     and r.source_status in ('ACTIVE','IN_TENANT'))))
$$;

do $migration$
declare d text:=pg_get_functiondef('private.walkthrough_entry_json(uuid)'::regprocedure);
begin
 if strpos(d,'else e.expected end')=0 then raise exception 'Walk-Through response integration point changed';end if;
 execute replace(d,'else e.expected end',$new$when exists(select 1 from automation.lock_mirror_control where id and mode='mirror')
  then (e.expected-'assignmentReview'-'sourceReview')||'{"mirrorMode":true,"missing":false}'::jsonb else e.expected end$new$);
end
$migration$;
