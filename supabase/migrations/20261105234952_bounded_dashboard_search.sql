-- Existing RLS is unchanged. Bound dashboard work and preserve full totals for inventory.
drop function public.inventory_listing(text,uuid,text[],text,int,int);
create index locks_identifier_order on public.locks(facility_id,
 (case when serial ~ '^[0-9]+$' then 0 when serial ~ '^[0-9]' then 1 else 2 end),
 ((case when serial ~ '^[0-9]' and serial !~ '^[0-9]+$' then substring(serial from '^[0-9]+') else '' end) collate "C"),
 serial collate public.inventory_natural,lower(serial) collate "C",serial collate "C",id);
create function public.inventory_listing(p_query text default '',p_facility uuid default null,p_statuses text[] default null,p_sort text default 'serial',p_limit int default 100,p_offset int default 0,p_exact_count boolean default true) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare needle text:=lower(regexp_replace(coalesce(p_query,''),'[^a-zA-Z0-9]','','g'));result jsonb;f record;chunk jsonb;items jsonb:='[]';needed int;
begin
 if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
 if p_facility is not null and not private.can_access(p_facility) then raise exception 'Facility access denied' using errcode='42501';end if;
 if p_sort not in ('serial','facility_serial','updated_at','created_at') or p_limit not between 1 and 500 or p_offset<0 then raise exception 'Invalid inventory query';end if;
 -- Dashboard results need a bounded list, not an exact count of every match.
 if not p_exact_count and p_offset=0 and (p_sort='facility_serial' or (p_sort='serial' and p_facility is not null)) then
  for f in select id,name from public.facilities where p_facility is null or id=p_facility order by name collate public.inventory_natural,id loop
   needed:=p_limit+1-jsonb_array_length(items);
   select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) into chunk from (
    select l.*,f.name as facility_name from public.locks l
    where l.facility_id=f.id and (p_statuses is null or l.status=any(p_statuses))
     and (coalesce(p_query,'')='' or (needle<>'' and lower(l.serial) like '%'||needle||'%'))
    order by
     case when l.serial ~ '^[0-9]+$' then 0 when l.serial ~ '^[0-9]' then 1 else 2 end,
     (case when l.serial ~ '^[0-9]' and l.serial !~ '^[0-9]+$' then substring(l.serial from '^[0-9]+') else '' end) collate "C",
     l.serial collate public.inventory_natural,lower(l.serial) collate "C",l.serial collate "C",l.id
    limit needed
   ) q;
   items:=items||chunk;exit when jsonb_array_length(items)>p_limit;
  end loop;
  return jsonb_build_object('items',coalesce((select jsonb_agg(value) from (select value from jsonb_array_elements(items) with ordinality x(value,n) where n<=p_limit order by n) shown),'[]'::jsonb),'total',null,'hasMore',jsonb_array_length(items)>p_limit);
 end if;
 with visible_facilities as materialized (select id,name from public.facilities where p_facility is null or id=p_facility), filtered as materialized (
  select l.*,f.name as facility_name,
   case when l.serial ~ '^[0-9]+$' then 0 when l.serial ~ '^[0-9]' then 1 else 2 end as serial_kind,
   case when l.serial ~ '^[0-9]' and l.serial !~ '^[0-9]+$' then substring(l.serial from '^[0-9]+') else '' end as serial_prefix
  from public.locks l join visible_facilities f on f.id=l.facility_id
  where (p_facility is null or l.facility_id=p_facility)
   and (p_statuses is null or l.status=any(p_statuses))
   and (coalesce(p_query,'')='' or (needle<>'' and lower(l.serial) like '%'||needle||'%'))
 ), page as (
  select * from filtered order by
   case when p_sort='facility_serial' then facility_name end collate public.inventory_natural,
   case when p_sort='updated_at' then updated_at end desc nulls last,
   case when p_sort='created_at' then created_at end desc nulls last,
   serial_kind,serial_prefix collate "C",serial collate public.inventory_natural,lower(serial) collate "C",serial collate "C",facility_id,id
  limit (p_limit+case when p_exact_count then 0 else 1 end) offset p_offset
 )
 select jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(shown)-'serial_kind'-'serial_prefix') from (select * from page limit p_limit) shown),'[]'::jsonb),'total',case when p_exact_count then (select count(*) from filtered) else null end,'hasMore',(select count(*) from page)>p_limit) into result;
 return result;
end $$;

revoke execute on function public.inventory_listing(text,uuid,text[],text,int,int,boolean) from public,anon;
grant execute on function public.inventory_listing(text,uuid,text[],text,int,int,boolean) to authenticated;
