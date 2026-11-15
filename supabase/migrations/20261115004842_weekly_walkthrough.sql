-- Findings are private, separate from Cubby state and physical lock inventory.
create table private.walkthrough_sources(facility_id uuid primary key references public.facilities,units jsonb not null,ordering text not null,observed_at timestamptz not null);
create table private.walkthrough_policies(facility_id uuid primary key references public.facilities,vacant_required boolean,auction_lock_type text not null default 'auction' check(auction_lock_type in ('auction','overlock','none')),updated_by uuid references public.profiles,updated_at timestamptz not null default now());
create table private.walkthrough_weeks(id uuid primary key default gen_random_uuid(),facility_id uuid not null references public.facilities,week_start date not null,ordering text not null,created_at timestamptz not null default now(),completed_at timestamptz,completed_by uuid references public.profiles,unique(facility_id,week_start));
create table private.walkthrough_entries(id uuid primary key default gen_random_uuid(),week_id uuid not null references private.walkthrough_weeks,unit_source_id text not null,position int not null,expected jsonb not null,result text not null default 'unchecked' check(result in ('unchecked','confirmed','issue')),issue text check(issue in ('Moved Out','No tenant lock','Unexpected Lock','Incorrect Overlock','Door/Latch Damage','Other')),notes text not null default '' check(length(notes)<=2000),version int not null default 1,checked_by uuid references public.profiles,checked_at timestamptz,unique(week_id,unit_source_id));
create index walkthrough_week_position on private.walkthrough_entries(week_id,position,id);
create table private.walkthrough_events(id bigint generated always as identity primary key,entry_id uuid references private.walkthrough_entries,week_id uuid not null references private.walkthrough_weeks,actor_id uuid references public.profiles,action text not null,expected jsonb,observed_result text,issue text,notes text,at timestamptz not null default now());
alter table private.walkthrough_sources enable row level security;
alter table private.walkthrough_policies enable row level security;
alter table private.walkthrough_weeks enable row level security;
alter table private.walkthrough_entries enable row level security;
alter table private.walkthrough_events enable row level security;
revoke all on private.walkthrough_sources,private.walkthrough_policies,private.walkthrough_weeks,private.walkthrough_entries,private.walkthrough_events from public,anon,authenticated;
alter table public.action_items add column unit_label text,add column reported_by uuid references public.profiles,add column reported_at timestamptz,add column lock_type text;
alter table public.action_items drop constraint action_items_kind_check;
alter table public.action_items add constraint action_items_kind_check check(kind in ('overlock_removal','vacant_recovery','missing_assignment','sms_failure','assignment_conflict','sync_failure','walkthrough_issue','walkthrough_missing'));

create function private.walkthrough_expected(fid uuid,u jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 with policy as (select coalesce((select auction_lock_type from private.walkthrough_policies where facility_id=fid),'auction') as auction_type,(select vacant_required from private.walkthrough_policies where facility_id=fid) as vacant),
 desired as (select case u->>'kind' when 'overlock' then 'overlock' when 'auction' then nullif(auction_type,'none') when 'vacant' then case when vacant then 'vacant' end end as typ,vacant from policy),
 assigned as (select l.id,l.serial,l.status from public.locks l where l.facility_id=fid and l.unit is not null and l.status in ('vacant','overlock','auction','unclassified','tenant_held') and (l.source_unit_id=u->>'unitId' or (l.source_unit_id is null and lower(trim(l.unit))=lower(trim(u->>'label')))) and exists(select 1 from public.assignments a where a.lock_id=l.id and a.released_at is null))
 select jsonb_build_object('label',u->>'label','kind',u->>'kind','tenantName',u->>'tenantName','auctionStatus',u->>'auctionStatus','unrentable',u->'unrentable','requiredType',typ,'vacantPolicyKnown',vacant is not null,'locks',coalesce((select jsonb_agg(jsonb_build_object('serial',serial,'status',status) order by serial collate public.inventory_natural) from assigned),'[]'::jsonb),'missing',typ is not null and not exists(select 1 from assigned where status=typ)) from desired;
$$;

create function private.walkthrough_missing(fid uuid) returns void language plpgsql security definer set search_path='' as $$
declare u jsonb;e jsonb;k text;begin
 for u in select value from private.walkthrough_sources s,jsonb_array_elements(s.units) where s.facility_id=fid loop
  e:=private.walkthrough_expected(fid,u);k:='walkthrough:missing:'||fid||':'||(u->>'unitId')||':'||coalesce(e->>'requiredType','none');
  if (e->>'missing')::boolean then
   insert into public.action_items(facility_id,kind,cause_key,title,detail,unit_label,lock_type,reported_at)
   values(fid,'walkthrough_missing',k,case e->>'requiredType' when 'vacant' then 'Add Vacant Lock' when 'overlock' then 'Add Overlock' else 'Add Auction Lock' end,'Inventory has no verified matching assignment. Inspect the unit; this does not establish whether a physical lock is present.',u->>'label',e->>'requiredType',now())
   on conflict(cause_key) do update set updated_at=now(),detail=excluded.detail where action_items.state='open';
  end if;
  update public.action_items set state='resolved',resolved_at=now(),updated_at=now() where facility_id=fid and kind='walkthrough_missing' and unit_label=u->>'label' and state='open' and (not (e->>'missing')::boolean or cause_key<>k);
 end loop;
end $$;

create function private.walkthrough_source_save(token text,fid uuid,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare h text;begin
 select worker_token_hash into h from automation.settings where id;
 if length(coalesce(token,''))<32 or h is null or encode(extensions.digest(token,'sha256'),'hex')<>h then raise exception 'Not authorized' using errcode='42501';end if;
 if not exists(select 1 from automation.facility_links where facility_id=fid) or jsonb_typeof(p->'units') is distinct from 'array' or jsonb_array_length(p->'units')>=1000 or pg_column_size(p)>1000000 or p->>'ordering' not in ('cubby','cubby_with_natural_fallback') then raise exception 'Source not verified';end if;
 if exists(select 1 from jsonb_array_elements(p->'units') u where nullif(u->>'unitId','') is null or nullif(u->>'label','') is null or u->>'kind' not in ('occupied','vacant','overlock','auction','unknown')) or (select count(*) from jsonb_array_elements(p->'units'))<>(select count(distinct u->>'unitId') from jsonb_array_elements(p->'units') u) then raise exception 'Source not verified';end if;
 insert into private.walkthrough_sources values(fid,p->'units',p->>'ordering',now()) on conflict(facility_id) do update set units=excluded.units,ordering=excluded.ordering,observed_at=now();
 perform private.walkthrough_missing(fid);return jsonb_build_object('ok',true);
end $$;
create function public.walkthrough_source_save(token text,fid uuid,p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.walkthrough_source_save(token,fid,p)$$;
revoke all on function private.walkthrough_expected(uuid,jsonb),private.walkthrough_missing(uuid),private.walkthrough_source_save(text,uuid,jsonb),public.walkthrough_source_save(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.walkthrough_source_save(text,uuid,jsonb),public.walkthrough_source_save(text,uuid,jsonb) to anon;

create function private.walkthrough_access(fid uuid) returns jsonb language plpgsql security definer set search_path='' as $$begin
 perform private.require_access(fid);return jsonb_build_object('refreshNeeded',not exists(select 1 from private.walkthrough_sources where facility_id=fid and observed_at>now()-interval '30 seconds'));
end $$;
create function public.walkthrough_access(fid uuid) returns jsonb language sql security invoker set search_path='' as $$select private.walkthrough_access(fid)$$;

create function private.walkthrough_page(fid uuid,sid uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare w private.walkthrough_weeks;s private.walkthrough_sources;u jsonb;new_expected jsonb;old private.walkthrough_entries;pos int;current_week date:=date_trunc('week',now() at time zone 'America/New_York')::date;begin
 perform private.require_access(fid);
 -- Serialize roster reconciliation within a facility; entry mutations separately lock their week.
 perform pg_advisory_xact_lock(hashtextextended('walkthrough:'||fid,0));
 select * into s from private.walkthrough_sources where facility_id=fid;
 if sid is null then
  if s.facility_id is null then return jsonb_build_object('sourceUnavailable',true,'items','[]'::jsonb);end if;
  insert into private.walkthrough_weeks(facility_id,week_start,ordering) values(fid,current_week,s.ordering) on conflict(facility_id,week_start) do nothing;
  select * into w from private.walkthrough_weeks where facility_id=fid and week_start=current_week for update;
  if s.observed_at>now()-interval '5 minutes' then
   select coalesce(max(position),0) into pos from private.walkthrough_entries where week_id=w.id;
   for u in select value from jsonb_array_elements(s.units) loop
    new_expected:=private.walkthrough_expected(fid,u);
    select * into old from private.walkthrough_entries where week_id=w.id and unit_source_id=u->>'unitId';
    if not found then
     pos:=pos+1;insert into private.walkthrough_entries(week_id,unit_source_id,position,expected) values(w.id,u->>'unitId',pos,new_expected);
     if w.completed_at is not null then update private.walkthrough_weeks set completed_at=null,completed_by=null where id=w.id;end if;
    elsif old.expected is distinct from new_expected then
     insert into private.walkthrough_events(entry_id,week_id,action,expected,observed_result,issue,notes) values(old.id,w.id,'expected_condition_changed',old.expected,old.result,old.issue,old.notes);
     update private.walkthrough_entries set expected=new_expected,result='unchecked',issue=null,version=version+1,checked_by=null,checked_at=null where id=old.id;
     update private.walkthrough_weeks set completed_at=null,completed_by=null where id=w.id;
    end if;
   end loop;
   perform private.walkthrough_missing(fid);
  end if;
 else select * into w from private.walkthrough_weeks where id=sid and facility_id=fid;end if;
 if w.id is null then raise exception 'Inspection unavailable';end if;
 return jsonb_build_object('id',w.id,'weekStart',w.week_start,'completedAt',(select completed_at from private.walkthrough_weeks where id=w.id),'ordering',w.ordering,'historical',w.week_start<>current_week,'stale',s.observed_at is null or s.observed_at<now()-interval '5 minutes','refreshedAt',s.observed_at,'policy',jsonb_build_object('vacantRequired',(select vacant_required from private.walkthrough_policies where facility_id=fid),'auctionLockType',coalesce((select auction_lock_type from private.walkthrough_policies where facility_id=fid),'auction')),'items',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'expected',e.expected,'result',e.result,'issue',e.issue,'notes',e.notes,'version',e.version,'manager',p.name,'checkedAt',e.checked_at) order by e.position,e.id) from private.walkthrough_entries e left join public.profiles p on p.id=e.checked_by where e.week_id=w.id),'[]'::jsonb),'history',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'weekStart',h.week_start,'completedAt',h.completed_at) order by h.week_start desc) from (select * from private.walkthrough_weeks where facility_id=fid order by week_start desc limit 20) h),'[]'::jsonb));
end $$;
create function public.walkthrough_page(fid uuid,sid uuid default null) returns jsonb language sql security invoker set search_path='' as $$select private.walkthrough_page(fid,sid)$$;

create function private.walkthrough_record(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w private.walkthrough_weeks;e private.walkthrough_entries;result_value text:=p->>'result';issue_value text:=nullif(p->>'issue','');begin
 select * into w from private.walkthrough_weeks where id=(p->>'weekId')::uuid for update;
 if w.id is null then raise exception 'Inspection unavailable';end if;perform private.require_access(w.facility_id);
 if w.week_start<>date_trunc('week',now() at time zone 'America/New_York')::date then raise exception 'Historical inspections cannot be changed';end if;
 if not exists(select 1 from private.walkthrough_sources where facility_id=w.facility_id and observed_at>now()-interval '5 minutes') then raise exception 'Refresh Cubby information before continuing';end if;
 if p->>'action'='complete' then
  if not exists(select 1 from private.walkthrough_entries where week_id=w.id) or exists(select 1 from private.walkthrough_entries where week_id=w.id and result='unchecked') then raise exception 'Inspect every unit before completing';end if;
  if exists(select 1 from private.walkthrough_entries entry_row where entry_row.week_id=w.id and entry_row.expected is distinct from (select private.walkthrough_expected(w.facility_id,u) from private.walkthrough_sources s,jsonb_array_elements(s.units) u where s.facility_id=w.facility_id and u->>'unitId'=entry_row.unit_source_id)) then raise exception 'Unit information changed. Refresh before completing.';end if;
  update private.walkthrough_weeks set completed_at=now(),completed_by=auth.uid() where id=w.id;
  insert into private.walkthrough_events(week_id,actor_id,action) values(w.id,auth.uid(),'completed');return jsonb_build_object('ok',true);
 end if;
 select * into e from private.walkthrough_entries where id=(p->>'entryId')::uuid and week_id=w.id for update;
 if e.id is null or e.version is distinct from (p->>'version')::int then raise exception 'This unit changed. Refresh and review before saving.' using errcode='40001';end if;
 if result_value not in ('unchecked','confirmed','issue') or result_value is null or (result_value='issue' and (issue_value is null or issue_value not in ('Moved Out','No tenant lock','Unexpected Lock','Incorrect Overlock','Door/Latch Damage','Other'))) then raise exception 'Select a valid inspection result';end if;
 if result_value='confirmed' and e.expected->>'kind'='unknown' then raise exception 'Source information is incomplete; record an exception';end if;
 -- Recheck expected condition and assignments at the save boundary.
 if e.expected is distinct from (select private.walkthrough_expected(w.facility_id,u) from private.walkthrough_sources s,jsonb_array_elements(s.units) u where s.facility_id=w.facility_id and u->>'unitId'=e.unit_source_id) then raise exception 'This unit changed. Refresh and review before saving.' using errcode='40001';end if;
 update private.walkthrough_entries set result=result_value,issue=case when result_value='issue' then issue_value end,notes=coalesce(p->>'notes',''),version=version+1,checked_by=auth.uid(),checked_at=now() where id=e.id;
 update private.walkthrough_weeks set completed_at=null,completed_by=null where id=w.id;
 insert into private.walkthrough_events(entry_id,week_id,actor_id,action,expected,observed_result,issue,notes) values(e.id,w.id,auth.uid(),'inspection_saved',e.expected,result_value,case when result_value='issue' then issue_value end,coalesce(p->>'notes',''));
 update public.action_items set state='resolved',resolved_at=now(),resolved_by=auth.uid(),updated_at=now() where facility_id=w.facility_id and kind='walkthrough_issue' and cause_key like 'walkthrough:issue:'||w.facility_id||':'||e.unit_source_id||':%' and state='open' and (result_value<>'issue' or cause_key<>'walkthrough:issue:'||w.facility_id||':'||e.unit_source_id||':'||issue_value);
 if result_value='issue' then
  insert into public.action_items(facility_id,kind,cause_key,title,detail,unit_label,reported_by,reported_at) values(w.facility_id,'walkthrough_issue','walkthrough:issue:'||w.facility_id||':'||e.unit_source_id||':'||issue_value,issue_value,'Reported during the weekly walk-through. Review the unit and resolve the condition.'||case when nullif(p->>'notes','') is not null then ' Notes: '||(p->>'notes') else '' end,e.expected->>'label',auth.uid(),now()) on conflict(cause_key) do update set state=case when e.result='issue' and e.issue=issue_value then action_items.state else 'open' end,resolved_at=case when e.result='issue' and e.issue=issue_value then action_items.resolved_at end,resolved_by=case when e.result='issue' and e.issue=issue_value then action_items.resolved_by end,detail=excluded.detail,reported_by=auth.uid(),reported_at=now(),updated_at=now();
 end if;
 return jsonb_build_object('ok',true);
end $$;
create function public.walkthrough_record(p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.walkthrough_record(p)$$;
create function private.walkthrough_policy(fid uuid,vacant_required boolean,auction_lock_type text) returns jsonb language plpgsql security definer set search_path='' as $$begin
 perform private.require_access(fid);if not private.admin() then raise exception 'Administrator required' using errcode='42501';end if;
 insert into private.walkthrough_policies values(fid,vacant_required,auction_lock_type,auth.uid(),now()) on conflict(facility_id) do update set vacant_required=excluded.vacant_required,auction_lock_type=excluded.auction_lock_type,updated_by=auth.uid(),updated_at=now();
 return jsonb_build_object('ok',true);
end $$;
create function public.walkthrough_policy(fid uuid,vacant_required boolean,auction_lock_type text) returns jsonb language sql security invoker set search_path='' as $$select private.walkthrough_policy(fid,vacant_required,auction_lock_type)$$;
revoke all on function private.walkthrough_access(uuid),public.walkthrough_access(uuid),private.walkthrough_page(uuid,uuid),public.walkthrough_page(uuid,uuid),private.walkthrough_record(jsonb),public.walkthrough_record(jsonb),private.walkthrough_policy(uuid,boolean,text),public.walkthrough_policy(uuid,boolean,text) from public,anon,authenticated;
grant execute on function private.walkthrough_access(uuid),public.walkthrough_access(uuid),private.walkthrough_page(uuid,uuid),public.walkthrough_page(uuid,uuid),private.walkthrough_record(jsonb),public.walkthrough_record(jsonb),private.walkthrough_policy(uuid,boolean,text),public.walkthrough_policy(uuid,boolean,text) to authenticated;

create or replace function automation.dashboard(fid uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;if fid is not null then perform private.require_access(fid);end if;
 return jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(t)) from (
 select a.id,a.kind,
 case when a.kind in ('walkthrough_issue','walkthrough_missing') then a.title when a.kind='overlock_removal' then 'Overlock removal required' when a.kind='vacant_recovery' then 'Vacant lock recovery required' when a.kind='missing_assignment' then 'Physical lock assignment needed' when a.kind='sms_failure' then 'Tenant notification needs attention' when a.kind='sync_failure' then 'Automatic access messages need attention' else 'Lock assignment needs review' end as title,
 case when a.kind in ('walkthrough_issue','walkthrough_missing') then a.detail when a.kind in ('overlock_removal','vacant_recovery') then 'Confirm the physical lock has been recovered before returning it to inventory.' when a.kind='missing_assignment' then 'Check the unit and confirm the correct physical lock assignment.' when a.kind='sms_failure' then 'Confirm whether the tenant received access instructions before sending another message.' when a.kind='sync_failure' then 'Contact an administrator. Physical lock management remains available.' else 'Check the current lock assignment and tenant access before sending a combination.' end as detail,
 a.eligibility_state,a.notification_state,a.recovered_at is not null as recovered,f.name as "facilityName",a.unit_label as unit,p.name as manager,a.reported_at as "reportedAt",a.lock_type as "lockType",case when a.kind='walkthrough_missing' then a.facility_id end as "assignmentFacility"
 from public.action_items a left join public.facilities f on f.id=a.facility_id left join public.profiles p on p.id=a.reported_by
 where a.state='open' and (private.admin() or (a.facility_id is not null and private.can_access(a.facility_id))) and (fid is null or a.facility_id=fid)
 order by a.created_at desc limit 200) t),'[]'::jsonb));
end $$;
