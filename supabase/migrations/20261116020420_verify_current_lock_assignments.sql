-- Use current local bindings; frozen Cubby import IDs remain provenance only.
-- An existing lock with unknown purpose requires review, not an additional lock.
create or replace function private.walkthrough_expected(fid uuid,u jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 with policy as (select coalesce((select auction_lock_type from private.walkthrough_policies where facility_id=fid),'auction') as auction_type,(select vacant_required from private.walkthrough_policies where facility_id=fid) as vacant),
 desired as (select case u->>'kind' when 'overlock' then 'overlock' when 'auction' then nullif(auction_type,'none') when 'vacant' then case when vacant then 'vacant' end end as typ,vacant from policy),
 identity as (select count(*)=1 as unique_unit from private.walkthrough_sources s,jsonb_array_elements(s.units) x where s.facility_id=fid and lower(trim(x->>'label'))=lower(trim(u->>'label'))),
 assigned as (
  select l.id,l.serial,l.status,
   a.facility_id=fid and a.type=l.status and lower(trim(l.unit))=lower(trim(a.unit)) and (select unique_unit from identity) as consistent
  from public.locks l join public.assignments a on a.lock_id=l.id and a.released_at is null
  where l.facility_id=fid and l.status in ('vacant','overlock','auction','unclassified','tenant_held','maintenance')
   and (lower(trim(l.unit))=lower(trim(u->>'label')) or lower(trim(a.unit))=lower(trim(u->>'label')))
 ),
 evaluation as (select *,exists(select 1 from assigned where status=typ and consistent) as verified,exists(select 1 from assigned) as present from desired,identity)
 select jsonb_build_object('label',u->>'label','kind',u->>'kind','tenantName',u->>'tenantName','auctionStatus',u->>'auctionStatus','unrentable',u->'unrentable','requiredType',typ,'vacantPolicyKnown',vacant is not null,
  'locks',coalesce((select jsonb_agg(jsonb_build_object('serial',serial,'status',status) order by serial collate public.inventory_natural) from assigned),'[]'::jsonb),
  'missing',typ is not null and unique_unit and not present)
  ||case when typ is not null and not verified and (present or not unique_unit) then '{"assignmentReview":true}'::jsonb else '{}'::jsonb end
 from evaluation;
$$;

create or replace function private.walkthrough_missing(fid uuid) returns void language plpgsql security definer set search_path='' as $$
declare u jsonb;e jsonb;k text;review boolean;begin
 -- Stale expectations cannot close or reinterpret an operational task.
 if not exists(select 1 from private.walkthrough_sources where facility_id=fid and observed_at>now()-interval '5 minutes') then return;end if;
 for u in select value from private.walkthrough_sources s,jsonb_array_elements(s.units) where s.facility_id=fid loop
  e:=private.walkthrough_expected(fid,u);review:=coalesce((e->>'assignmentReview')::boolean,false);
  k:='walkthrough:missing:'||fid||':'||(u->>'unitId')||':'||coalesce(e->>'requiredType','none');
  if (e->>'missing')::boolean or review then
   insert into public.action_items(facility_id,kind,cause_key,title,detail,unit_label,lock_type,reported_at)
   values(fid,'walkthrough_missing',k,
    case when review then 'Verify assigned lock purpose' when e->>'requiredType'='vacant' then 'Add Vacant Lock' when e->>'requiredType'='overlock' then 'Add Overlock' else 'Add Auction Lock' end,
    case when review then 'A lock or conflicting unit mapping is recorded. Verify the existing assignment and its purpose before adding another lock.' else 'Inventory has no verified matching assignment. Inspect the unit; this does not establish whether a physical lock is present.' end,
    u->>'label',case when not review then e->>'requiredType' end,now())
   on conflict(cause_key) do update set updated_at=now(),title=excluded.title,detail=excluded.detail,lock_type=excluded.lock_type where action_items.state='open';
  end if;
  update public.action_items set state='resolved',resolved_at=now(),updated_at=now()
   where facility_id=fid and kind='walkthrough_missing' and unit_label=u->>'label' and state='open'
   and ((not (e->>'missing')::boolean and not review) or cause_key<>k);
 end loop;
end $$;

-- Backend-only before/after evidence. Never contains combination material.
create table private.lock_assignment_reconciliations(
 id uuid primary key default gen_random_uuid(),lock_id uuid not null references public.locks,
 facility_id uuid not null references public.facilities,source_lock_id text not null,
 source_observed_at timestamptz not null,source_updated_at timestamptz,
 before_binding jsonb not null,after_binding jsonb not null,reason text not null,
 reconciled_at timestamptz not null default now()
);
alter table private.lock_assignment_reconciliations enable row level security;
revoke all on private.lock_assignment_reconciliations from public,anon,authenticated;
