create temporary table walkthrough_delete_preservation on commit drop as select w.id,to_jsonb(w) as metadata,
 (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_entries e where e.week_id=w.id) as entries,
 (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_events e where e.week_id=w.id) as events
 from private.walkthrough_weeks w where w.status<>'discarded' or w.completed_at is not null;

-- A deletion audit is a tombstone, not a recoverable inspection snapshot.
create table private.walkthrough_deletions(
 inspection_id uuid primary key,
 facility_id uuid not null references public.facilities,
 deleted_by uuid references public.profiles,
 deleted_at timestamptz not null default clock_timestamp(),
 reason text not null check(reason in ('manager_discard','legacy_discard')),
 start_request_id uuid unique
);
alter table private.walkthrough_deletions enable row level security;
revoke all on private.walkthrough_deletions from public,anon,authenticated;

-- Internal only. Caller holds the facility and inspection locks and verifies access.
create function private.walkthrough_delete_owned(sid uuid,actor uuid,why text) returns void
language plpgsql security definer set search_path='' as $$
declare w private.walkthrough_weeks;begin
 select * into w from private.walkthrough_weeks where id=sid for update;
 if w.id is null or w.status='completed' or w.completed_at is not null then raise exception 'Only unfinished inspections can be deleted';end if;
 insert into private.walkthrough_deletions(inspection_id,facility_id,deleted_by,reason,start_request_id)
 values(w.id,w.facility_id,actor,why,w.start_request_id);
 -- Purge only this inspection's recoverable data. Shared operational tasks and security logs stay intact.
 delete from private.walkthrough_reset_archive where original_week_id=w.id;
 delete from private.walkthrough_events where week_id=w.id;
 delete from private.walkthrough_entries where week_id=w.id;
 delete from private.walkthrough_weeks where id=w.id;
end $$;
revoke all on function private.walkthrough_delete_owned(uuid,uuid,text) from public,anon,authenticated;

do $$declare definition text;guard text:='if w.version is distinct from (p->>''version'')::integer then raise exception ''This inspection changed. Refresh before continuing.'' using errcode=''40001'';end if;';begin
 definition:=pg_get_functiondef('private.walkthrough_session(jsonb)'::regprocedure);
 if strpos(definition,guard)=0 or strpos(definition,'select * into w from private.walkthrough_weeks where start_request_id=request_id;')=0 then raise exception 'Session workflow changed; review permanent deletion migration';end if;
 definition:=replace(definition,guard,guard||$body$
  if act='discard' then
   if p->'permanent' is distinct from 'true'::jsonb then raise exception 'Confirm permanent deletion before continuing';end if;
   perform private.walkthrough_delete_owned(w.id,auth.uid(),'manager_discard');
   return private.walkthrough_page(fid,null);
  end if;
$body$);
 -- Tombstones also prevent an old retried New request from recreating a deleted inspection.
 definition:=replace(definition,'select * into w from private.walkthrough_weeks where start_request_id=request_id;',
  'if exists(select 1 from private.walkthrough_deletions where start_request_id=request_id) then raise exception ''Request unavailable'';end if; select * into w from private.walkthrough_weeks where start_request_id=request_id;');
 -- Remove the now-unreachable soft-discard branch. Restart retention remains unchanged.
 definition:=replace(definition,'else update private.walkthrough_weeks set status=''discarded'',discarded_at=clock_timestamp(),discarded_by=auth.uid(),version=version+1 where id=w.id;end if;','end if;');
 execute definition;
end $$;

-- Apply the new semantics to previously discarded sessions only; active and completed rows are untouched.
do $$declare w private.walkthrough_weeks;begin
 for w in select * from private.walkthrough_weeks where status='discarded' and completed_at is null order by facility_id,id loop
  perform pg_advisory_xact_lock(hashtextextended('walkthrough:'||w.facility_id,0));
  perform private.walkthrough_delete_owned(w.id,w.discarded_by,'legacy_discard');
 end loop;
end $$;

do $$begin
 if exists(select 1 from walkthrough_delete_preservation b left join private.walkthrough_weeks w on w.id=b.id
 where w.id is null or b.metadata is distinct from to_jsonb(w)
 or b.entries is distinct from (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_entries e where e.week_id=w.id)
 or b.events is distinct from (select md5(coalesce(string_agg(to_jsonb(e)::text,',' order by e.id),'')) from private.walkthrough_events e where e.week_id=w.id)) then raise exception 'Unrelated inspections did not reconcile';end if;
end $$;
