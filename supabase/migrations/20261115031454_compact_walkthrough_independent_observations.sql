-- Add independent observations without deleting or reinterpreting existing history.
alter table private.walkthrough_entries add column confirmed boolean,add column confirmed_by uuid references public.profiles,add column confirmed_at timestamptz,add column issue_by uuid references public.profiles,add column issue_at timestamptz;
alter table private.walkthrough_entries alter column confirmed set default false;

alter table private.walkthrough_events add column confirmed boolean;

create function private.walkthrough_entry_json(eid uuid) returns jsonb language sql stable security definer set search_path='' as $$
select jsonb_build_object('id',e.id,'expected',e.expected,'result',e.result,'confirmed',coalesce(e.confirmed,e.result='confirmed'),'issue',e.issue,'notes',e.notes,'version',e.version,'manager',p.name,'checkedAt',e.checked_at,'confirmedManager',coalesce(cp.name,case when e.confirmed is null and e.result='confirmed' then p.name end),'confirmedAt',coalesce(e.confirmed_at,case when e.confirmed is null and e.result='confirmed' then e.checked_at end),'issueManager',coalesce(ip.name,case when e.issue is not null then p.name end),'issueAt',coalesce(e.issue_at,case when e.issue is not null then e.checked_at end))
from private.walkthrough_entries e left join public.profiles p on p.id=e.checked_by left join public.profiles cp on cp.id=e.confirmed_by left join public.profiles ip on ip.id=e.issue_by where e.id=eid;
$$;
revoke all on function private.walkthrough_entry_json(uuid) from public,anon,authenticated;

create or replace function private.walkthrough_page(fid uuid,sid uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
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
     insert into private.walkthrough_events(entry_id,week_id,action,expected,observed_result,issue,notes,confirmed) values(old.id,w.id,'expected_condition_changed',old.expected,old.result,old.issue,old.notes,old.confirmed);
     update private.walkthrough_entries set expected=new_expected,confirmed=false,confirmed_by=null,confirmed_at=null,result=case when issue is not null then 'issue' else 'unchecked' end,version=version+1 where id=old.id;
     update private.walkthrough_weeks set completed_at=null,completed_by=null where id=w.id;
    end if;
   end loop;
   perform private.walkthrough_missing(fid);
  end if;
 else select * into w from private.walkthrough_weeks where id=sid and facility_id=fid;end if;
 if w.id is null then raise exception 'Inspection unavailable';end if;
 return jsonb_build_object('id',w.id,'weekStart',w.week_start,'completedAt',(select completed_at from private.walkthrough_weeks where id=w.id),'ordering',w.ordering,'historical',w.week_start<>current_week,'stale',s.observed_at is null or s.observed_at<now()-interval '5 minutes','refreshedAt',s.observed_at,'policy',jsonb_build_object('vacantRequired',(select vacant_required from private.walkthrough_policies where facility_id=fid),'auctionLockType',coalesce((select auction_lock_type from private.walkthrough_policies where facility_id=fid),'auction')),'items',coalesce((select jsonb_agg(private.walkthrough_entry_json(e.id) order by e.position,e.id) from private.walkthrough_entries e left join public.profiles p on p.id=e.checked_by where e.week_id=w.id),'[]'::jsonb),'history',coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'weekStart',h.week_start,'completedAt',h.completed_at) order by h.week_start desc) from (select * from private.walkthrough_weeks where facility_id=fid order by week_start desc limit 20) h),'[]'::jsonb));
end $$;
create or replace function private.walkthrough_record(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w private.walkthrough_weeks;e private.walkthrough_entries;act text:=p->>'action';new_confirmed boolean;new_issue text;new_notes text;new_result text;issue_edit boolean:=false;begin
 select * into w from private.walkthrough_weeks where id=(p->>'weekId')::uuid for update;
 if w.id is null then raise exception 'Inspection unavailable';end if;perform private.require_access(w.facility_id);
 if w.week_start<>date_trunc('week',now() at time zone 'America/New_York')::date then raise exception 'Historical inspections cannot be changed';end if;
 if not exists(select 1 from private.walkthrough_sources where facility_id=w.facility_id and observed_at>now()-interval '5 minutes') then raise exception 'Refresh Cubby information before continuing';end if;
 if act='complete' then
  if not exists(select 1 from private.walkthrough_entries where week_id=w.id) or exists(select 1 from private.walkthrough_entries where week_id=w.id and not coalesce(confirmed,result='confirmed') and issue is null) then raise exception 'Inspect every unit before completing';end if;
  if exists(select 1 from private.walkthrough_entries entry_row where entry_row.week_id=w.id and entry_row.expected is distinct from (select private.walkthrough_expected(w.facility_id,u) from private.walkthrough_sources s,jsonb_array_elements(s.units) u where s.facility_id=w.facility_id and u->>'unitId'=entry_row.unit_source_id)) then raise exception 'Unit information changed. Refresh before completing.';end if;
  update private.walkthrough_weeks set completed_at=now(),completed_by=auth.uid() where id=w.id;
  insert into private.walkthrough_events(week_id,actor_id,action) values(w.id,auth.uid(),'completed');return jsonb_build_object('ok',true,'completedAt',now());
 end if;
 select * into e from private.walkthrough_entries where id=(p->>'entryId')::uuid and week_id=w.id for update;
 if e.id is null or e.version is distinct from (p->>'version')::int then raise exception 'This unit changed. Refresh and review before saving.' using errcode='40001';end if;
 new_confirmed:=coalesce(e.confirmed,e.result='confirmed');new_issue:=e.issue;new_notes:=e.notes;
 if act='set_confirmation' then
  if jsonb_typeof(p->'confirmed') is distinct from 'boolean' then raise exception 'Select a valid confirmation';end if;
  new_confirmed:=(p->>'confirmed')::boolean;
 elsif act='set_issue' then
  if not (p ? 'issue') or (p->'issue'<>'null'::jsonb and jsonb_typeof(p->'issue') is distinct from 'string') then raise exception 'Select a valid issue';end if;
  new_issue:=nullif(p->>'issue','');issue_edit:=true;
 elsif act='set_notes' then
  if jsonb_typeof(p->'notes') is distinct from 'string' then raise exception 'Enter valid notes';end if;
  new_notes:=p->>'notes';issue_edit:=new_issue is not null;
 elsif act is null then
  -- Older open tabs still use result. A confirmation must never erase an issue.
  if p->>'result'='confirmed' then new_confirmed:=true;
  elsif p->>'result'='issue' then new_issue:=nullif(p->>'issue','');issue_edit:=true;
  elsif p->>'result'='unchecked' then new_confirmed:=false;
  else raise exception 'Select a valid inspection result';end if;
 else raise exception 'Select a valid inspection action';end if;
 if issue_edit and p ? 'notes' then
  if jsonb_typeof(p->'notes') is distinct from 'string' then raise exception 'Enter valid notes';end if;new_notes:=p->>'notes';
 end if;
 if new_issue is not null and new_issue not in ('Moved Out','No tenant lock','Unexpected Lock','Incorrect Overlock','Door/Latch Damage','Other') then raise exception 'Select a valid issue';end if;
 if act is null and p->>'result'='issue' and new_issue is null then raise exception 'Select a valid issue';end if;
 if length(new_notes)>2000 then raise exception 'Notes are too long';end if;
 if new_confirmed and e.expected->>'kind'='unknown' then raise exception 'Source information is incomplete; record an exception';end if;
 if e.expected is distinct from (select private.walkthrough_expected(w.facility_id,u) from private.walkthrough_sources s,jsonb_array_elements(s.units) u where s.facility_id=w.facility_id and u->>'unitId'=e.unit_source_id) then raise exception 'This unit changed. Refresh and review before saving.' using errcode='40001';end if;
 new_result:=case when new_confirmed then 'confirmed' when new_issue is not null then 'issue' else 'unchecked' end;
 update private.walkthrough_entries set confirmed=new_confirmed,issue=new_issue,notes=new_notes,result=new_result,version=version+1,checked_by=auth.uid(),checked_at=now(),
  confirmed_by=case when new_confirmed=coalesce(e.confirmed,e.result='confirmed') then coalesce(confirmed_by,case when e.confirmed is null and e.result='confirmed' then checked_by end) when new_confirmed then auth.uid() end,
  confirmed_at=case when new_confirmed=coalesce(e.confirmed,e.result='confirmed') then coalesce(confirmed_at,case when e.confirmed is null and e.result='confirmed' then checked_at end) when new_confirmed then now() end,
  issue_by=case when not issue_edit then coalesce(issue_by,case when e.issue is not null then e.checked_by end) when new_issue is not null then auth.uid() end,
  issue_at=case when not issue_edit then coalesce(issue_at,case when e.issue is not null then e.checked_at end) when new_issue is not null then now() end where id=e.id;
 update private.walkthrough_weeks set completed_at=null,completed_by=null where id=w.id;
 insert into private.walkthrough_events(entry_id,week_id,actor_id,action,expected,observed_result,issue,notes,confirmed) values(e.id,w.id,auth.uid(),coalesce(act,'inspection_saved'),e.expected,new_result,new_issue,new_notes,new_confirmed);
 -- Confirmation and Undo do not touch issue tasks; only an explicit issue edit does.
 if issue_edit then
  update public.action_items set state='resolved',resolved_at=now(),resolved_by=auth.uid(),updated_at=now() where facility_id=w.facility_id and kind='walkthrough_issue' and cause_key like 'walkthrough:issue:'||w.facility_id||':'||e.unit_source_id||':%' and state='open' and (new_issue is null or cause_key<>'walkthrough:issue:'||w.facility_id||':'||e.unit_source_id||':'||new_issue);
  if new_issue is not null then
   insert into public.action_items(facility_id,kind,cause_key,title,detail,unit_label,reported_by,reported_at) values(w.facility_id,'walkthrough_issue','walkthrough:issue:'||w.facility_id||':'||e.unit_source_id||':'||new_issue,new_issue,'Reported during the weekly walk-through. Review the unit and resolve the condition.'||case when new_notes<>'' then ' Notes: '||new_notes else '' end,e.expected->>'label',auth.uid(),now())
   on conflict(cause_key) do update set state=case when e.issue=new_issue then action_items.state else 'open' end,resolved_at=case when e.issue=new_issue then action_items.resolved_at end,resolved_by=case when e.issue=new_issue then action_items.resolved_by end,detail=excluded.detail,reported_by=auth.uid(),reported_at=now(),updated_at=now();
  end if;
 end if;
 return jsonb_build_object('ok',true,'entry',private.walkthrough_entry_json(e.id),'completedAt',null);
end $$;

