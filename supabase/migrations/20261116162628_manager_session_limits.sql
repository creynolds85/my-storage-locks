-- Scope: My Storage Locks manager sessions. Worker-token and public tenant paths are unchanged.
create table private.manager_sessions(
 session_id uuid primary key references auth.sessions(id) on delete cascade,
 last_activity_at timestamptz not null
);
alter table private.manager_sessions enable row level security;
revoke all on private.manager_sessions from public,anon,authenticated;

create or replace function private.live() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from auth.sessions s left join private.manager_sessions m on m.session_id=s.id
  where s.id::text=auth.jwt()->>'session_id' and s.user_id=auth.uid()
   and (s.not_after is null or s.not_after>statement_timestamp())
   and s.created_at+interval '12 hours'>statement_timestamp()
   and coalesce(m.last_activity_at,s.created_at)+interval '30 minutes'>statement_timestamp()
 ) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active)
$$;

create function private.manager_session(activity boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare s auth.sessions; a timestamptz; t timestamptz;begin
 select * into s from auth.sessions where id::text=auth.jwt()->>'session_id' and user_id=auth.uid();
 if s.id is null or s.created_at is null or not exists(select 1 from public.profiles where id=auth.uid() and active) then return jsonb_build_object('active',false);end if;
 -- Untracked sessions start at their real sign-in time, never token refresh/reopen time.
 insert into private.manager_sessions(session_id,last_activity_at) values(s.id,s.created_at) on conflict do nothing;
 select last_activity_at into a from private.manager_sessions where session_id=s.id for update;
 t:=clock_timestamp();
 if (s.not_after is not null and s.not_after<=t) or s.created_at+interval '12 hours'<=t or a+interval '30 minutes'<=t then return jsonb_build_object('active',false);end if;
 -- Check before updating: an expired session can never be revived by an activity call.
 if activity is true then a:=t;update private.manager_sessions set last_activity_at=a where session_id=s.id;end if;
 return jsonb_build_object('active',true,'serverNow',extract(epoch from t)*1000,
  'idleExpiresAt',extract(epoch from a+interval '30 minutes')*1000,
  'absoluteExpiresAt',extract(epoch from least(s.created_at+interval '12 hours',coalesce(s.not_after,s.created_at+interval '12 hours')))*1000);
end $$;
create function public.manager_session(activity boolean default false) returns jsonb language sql security invoker set search_path='' as $$select private.manager_session(activity)$$;
revoke all on function private.manager_session(boolean),public.manager_session(boolean) from public,anon,authenticated;
grant execute on function private.manager_session(boolean),public.manager_session(boolean) to authenticated;
