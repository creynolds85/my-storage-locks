-- Read-only listing/search. Existing table RLS and live-session checks remain authoritative.
create collation public.inventory_natural (provider=icu,locale='und-u-kn-true-ks-level2',deterministic=false);
create index locks_natural_serial on public.locks(facility_id,serial collate public.inventory_natural,lower(serial) collate "C",serial collate "C",id);
create function public.inventory_listing(p_query text default '',p_facility uuid default null,p_statuses text[] default null,p_sort text default 'serial',p_limit int default 100,p_offset int default 0) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare needle text:=lower(regexp_replace(coalesce(p_query,''),'[^a-zA-Z0-9]','','g'));result jsonb;
begin
 if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
 if p_facility is not null and not private.can_access(p_facility) then raise exception 'Facility access denied' using errcode='42501';end if;
 if p_sort not in ('serial','facility_serial','updated_at','created_at') or p_limit not between 1 and 500 or p_offset<0 then raise exception 'Invalid inventory query';end if;
 with filtered as materialized (
  select l.*,f.name as facility_name from public.locks l join public.facilities f on f.id=l.facility_id
  where (p_facility is null or l.facility_id=p_facility)
   and (p_statuses is null or l.status=any(p_statuses))
   and (coalesce(p_query,'')='' or (needle<>'' and lower(l.serial) like '%'||needle||'%'))
 ), page as (
  select * from filtered order by
   case when p_sort='facility_serial' then facility_name end collate public.inventory_natural,
   case when p_sort='updated_at' then updated_at end desc nulls last,
   case when p_sort='created_at' then created_at end desc nulls last,
   serial collate public.inventory_natural,lower(serial) collate "C",serial collate "C",facility_id,id
  limit p_limit offset p_offset
 )
 select jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb),'total',(select count(*) from filtered)) into result;
 return result;
end $$;
revoke execute on function public.inventory_listing(text,uuid,text[],text,int,int) from public,anon;
grant execute on function public.inventory_listing(text,uuid,text[],text,int,int) to authenticated;
