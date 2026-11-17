create temporary table walkthrough_preservation on commit drop as select w.id,
 md5(row(w.id,w.facility_id,w.week_start,w.ordering,w.created_at,w.completed_at,w.completed_by)::text) as metadata,
 (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_entries e where e.week_id=w.id) as entries,
 (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_events e where e.week_id=w.id) as events
 from private.walkthrough_weeks w;
-- Extend existing inspection rows in place. No entry, confirmation, issue or event is rewritten.
alter table private.walkthrough_weeks drop constraint walkthrough_weeks_facility_id_week_start_key;
alter table private.walkthrough_weeks
 add column started_by uuid references public.profiles,
 add column status text not null default 'in_progress' check(status in ('in_progress','completed','discarded')),
 add column version integer not null default 1,
 add column start_request_id uuid unique,
 add column initial_snapshot jsonb,
 add column discarded_at timestamptz,
 add column discarded_by uuid references public.profiles;
update private.walkthrough_weeks set status='completed' where completed_at is not null;
create index walkthrough_facility_sessions on private.walkthrough_weeks(facility_id,status,created_at desc,id);

create function private.walkthrough_session_info(wid uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',w.id,'weekStart',w.week_start,'startedAt',w.created_at,'startedBy',sp.name,'status',w.status,'sessionVersion',w.version,
 'completedAt',w.completed_at,'completedBy',cp.name,'total',count(e.id),'inspected',count(e.id) filter(where coalesce(e.confirmed,e.result='confirmed') or e.issue is not null),'issues',count(e.id) filter(where e.issue is not null))
 from private.walkthrough_weeks w left join public.profiles sp on sp.id=w.started_by left join public.profiles cp on cp.id=w.completed_by
 left join private.walkthrough_entries e on e.week_id=w.id where w.id=wid group by w.id,sp.name,cp.name
$$;
revoke all on function private.walkthrough_session_info(uuid) from public,anon,authenticated;

create or replace function private.walkthrough_page(fid uuid,sid uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare w private.walkthrough_weeks;s private.walkthrough_sources;e private.walkthrough_entries;u jsonb;expected_now jsonb;changed boolean:=false;history jsonb;policy jsonb;begin
 perform private.require_access(fid);
 perform pg_advisory_xact_lock(hashtextextended('walkthrough:'||fid,0));
 select * into s from private.walkthrough_sources where facility_id=fid;
 -- Reading a facility never creates an inspection, including at a new calendar week.
 if sid is null then select * into w from private.walkthrough_weeks where facility_id=fid and status='in_progress' order by created_at desc,id desc limit 1 for update;
 else select * into w from private.walkthrough_weeks where id=sid and facility_id=fid and status<>'discarded' for update;
  if not found then raise exception 'Inspection unavailable';end if;
 end if;
 if w.id is not null and w.status='in_progress' and s.observed_at>now()-interval '5 minutes' then
  -- Preserve the session's original membership and route; only selected-session expectations reconcile.
  for e in select * from private.walkthrough_entries where week_id=w.id order by position,id loop
   select value into u from jsonb_array_elements(s.units) where value->>'unitId'=e.unit_source_id;
   if u is null then continue;end if;
   expected_now:=private.walkthrough_expected(fid,u);
   if e.expected is distinct from expected_now then
    insert into private.walkthrough_events(entry_id,week_id,actor_id,action,expected,observed_result,issue,notes,confirmed) values(e.id,w.id,null,'expected_condition_changed',e.expected,e.result,e.issue,e.notes,e.confirmed);
    update private.walkthrough_entries set expected=expected_now,confirmed=false,confirmed_by=null,confirmed_at=null,result=case when issue is null then 'unchecked' else 'issue' end,version=version+1 where id=e.id;
    changed:=true;
   end if;
  end loop;
  if changed then update private.walkthrough_weeks set version=version+1 where id=w.id returning * into w;end if;
 end if;
 select coalesce(jsonb_agg(private.walkthrough_session_info(h.id) order by h.created_at desc,h.id desc),'[]'::jsonb) into history from private.walkthrough_weeks h where h.facility_id=fid and h.status<>'discarded';
 policy:=jsonb_build_object('vacantRequired',(select vacant_required from private.walkthrough_policies where facility_id=fid),'auctionLockType',coalesce((select auction_lock_type from private.walkthrough_policies where facility_id=fid),'auction'));
 return coalesce(private.walkthrough_session_info(w.id),jsonb_build_object('id',null,'status',null))||jsonb_build_object('ordering',coalesce(w.ordering,s.ordering),'historical',w.status is not null and w.status<>'in_progress','stale',coalesce(w.status='in_progress' and (s.observed_at is null or s.observed_at<now()-interval '5 minutes'),false),'sourceUnavailable',s.facility_id is null,'refreshedAt',s.observed_at,'policy',policy,'history',history,'items',coalesce((select jsonb_agg(private.walkthrough_entry_json(x.id) order by x.position,x.id) from private.walkthrough_entries x where x.week_id=w.id),'[]'::jsonb));
end $$;

create function private.walkthrough_session(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare w private.walkthrough_weeks;s private.walkthrough_sources;fid uuid;act text:=p->>'action';request_id uuid;begin
 if act='new' then
  fid:=(p->>'facilityId')::uuid;perform private.require_access(fid);
  request_id:=(p->>'requestId')::uuid;if request_id is null then raise exception 'Request unavailable';end if;
  perform pg_advisory_xact_lock(hashtextextended('walkthrough:'||fid,0));
  select * into w from private.walkthrough_weeks where start_request_id=request_id;
  if found then
   if w.facility_id<>fid or w.started_by<>auth.uid() or w.status='discarded' then raise exception 'Request unavailable';end if;
   return private.walkthrough_page(fid,w.id);
  end if;
  select * into s from private.walkthrough_sources where facility_id=fid;
  if s.facility_id is null or s.observed_at<clock_timestamp()-interval '5 minutes' or jsonb_array_length(s.units)=0 then raise exception 'Refresh Cubby information before starting';end if;
  insert into private.walkthrough_weeks(facility_id,week_start,ordering,started_by,start_request_id,created_at)
   values(fid,date_trunc('week',now() at time zone 'America/New_York')::date,s.ordering,auth.uid(),request_id,clock_timestamp()) returning * into w;
  insert into private.walkthrough_entries(week_id,unit_source_id,position,expected)
   select w.id,u.value->>'unitId',u.n::integer,private.walkthrough_expected(fid,u.value) from jsonb_array_elements(s.units) with ordinality u(value,n);
  update private.walkthrough_weeks set initial_snapshot=jsonb_build_object('observedAt',s.observed_at,'ordering',s.ordering,'units',(select jsonb_agg(jsonb_build_object('unitId',e.unit_source_id,'position',e.position,'expected',e.expected) order by e.position) from private.walkthrough_entries e where e.week_id=w.id)) where id=w.id;
  insert into private.walkthrough_events(week_id,actor_id,action) values(w.id,auth.uid(),'started');
 elsif act in ('restart','discard') then
  -- Same lock order as page reconciliation and per-unit changes.
  select facility_id into fid from private.walkthrough_weeks where id=(p->>'sessionId')::uuid;perform private.require_access(fid);
  perform pg_advisory_xact_lock(hashtextextended('walkthrough:'||fid,0));
  select * into w from private.walkthrough_weeks where id=(p->>'sessionId')::uuid and facility_id=fid for update;
  if w.id is null or w.status<>'in_progress' then raise exception 'Only unfinished inspections can be changed';end if;
  if p->'acknowledged' is distinct from 'true'::jsonb then raise exception 'Confirm this inspection action';end if;
  if w.version is distinct from (p->>'version')::integer then raise exception 'This inspection changed. Refresh before continuing.' using errcode='40001';end if;
  insert into private.walkthrough_reset_archive(original_week_id,facility_id,reason,snapshot)
   values(w.id,w.facility_id,act||' requested by authenticated manager '||auth.uid()::text,jsonb_build_object('week',to_jsonb(w),'actorId',auth.uid(),'entries',(select coalesce(jsonb_agg(to_jsonb(e) order by e.position),'[]'::jsonb) from private.walkthrough_entries e where e.week_id=w.id)));
  if act='restart' then
   update private.walkthrough_entries set confirmed=false,confirmed_by=null,confirmed_at=null,result=case when issue is null then 'unchecked' else 'issue' end,
    checked_by=issue_by,checked_at=issue_at,version=version+1 where week_id=w.id;
   update private.walkthrough_weeks set version=version+1 where id=w.id;
  else update private.walkthrough_weeks set status='discarded',discarded_at=clock_timestamp(),discarded_by=auth.uid(),version=version+1 where id=w.id;end if;
  insert into private.walkthrough_events(week_id,actor_id,action) values(w.id,auth.uid(),act);
 else raise exception 'Choose a valid inspection action';end if;
 return private.walkthrough_page(fid,case when act='discard' then null else w.id end);
end $$;
create function public.walkthrough_session(p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.walkthrough_session(p)$$;
revoke all on function private.walkthrough_session(jsonb),public.walkthrough_session(jsonb) from public,anon,authenticated;
grant execute on function private.walkthrough_session(jsonb),public.walkthrough_session(jsonb) to authenticated;

-- Retain the established per-entry authorization, revision, freshness and issue logic.
do $$declare definition text;old_guard text:='if w.week_start<>date_trunc(''week'',now() at time zone ''America/New_York'')::date then raise exception ''Historical inspections cannot be changed'';end if;';begin
 definition:=pg_get_functiondef('private.walkthrough_record(jsonb)'::regprocedure);
 if strpos(definition,old_guard)=0 then raise exception 'Inspection mutation guard changed; review migration';end if;
 definition:=replace(definition,old_guard,'if w.status<>''in_progress'' then raise exception ''Only unfinished inspections can be changed'';end if;');
 definition:=replace(definition,'set completed_at=now(),completed_by=auth.uid() where id=w.id','set status=''completed'',completed_at=clock_timestamp(),completed_by=auth.uid(),version=version+1 where id=w.id');
 definition:=replace(definition,'''completedAt'',now())','''completedAt'',clock_timestamp(),''completedBy'',(select name from public.profiles where id=auth.uid()),''sessionVersion'',(select version from private.walkthrough_weeks where id=w.id))');
 definition:=replace(definition,'set completed_at=null,completed_by=null where id=w.id','set version=version+1 where id=w.id');
 definition:=replace(definition,'''completedAt'',null)','''completedAt'',null,''sessionVersion'',(select version from private.walkthrough_weeks where id=w.id))');
 execute definition;
end $$;

do $$begin
 if exists(select 1 from walkthrough_preservation b left join private.walkthrough_weeks w on w.id=b.id where w.id is null or b.metadata is distinct from md5(row(w.id,w.facility_id,w.week_start,w.ordering,w.created_at,w.completed_at,w.completed_by)::text) or b.entries is distinct from (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_entries e where e.week_id=w.id) or b.events is distinct from (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_events e where e.week_id=w.id)) then raise exception 'Existing inspections did not reconcile';end if;
end $$;
