-- Isolated session/inspection fixtures only. The caller runs this inside a rolled-back transaction.
insert into auth.users(id,email) values('97000000-0000-0000-0000-000000000001','session-limits@example.invalid');
insert into public.profiles(id,email,name,role) values('97000000-0000-0000-0000-000000000001','session-limits@example.invalid','Session Limits Fixture','employee');
insert into auth.sessions(id,user_id,created_at) values('97000000-0000-0000-0000-000000000002','97000000-0000-0000-0000-000000000001',clock_timestamp());
insert into public.facilities(id,name,identifier) values('97000000-0000-0000-0000-000000000003','Session Fixture','SESSION-LIMIT-QA');
insert into public.memberships values('97000000-0000-0000-0000-000000000001','97000000-0000-0000-0000-000000000003');
insert into private.walkthrough_sources values('97000000-0000-0000-0000-000000000003','[{"unitId":"session-fixture-unit","label":"TEST01","kind":"occupied","tenantName":"Isolated Fixture"}]','cubby',clock_timestamp());
select set_config('request.jwt.claims','{"sub":"97000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"97000000-0000-0000-0000-000000000002"}',true);
set local role authenticated;
do $$declare p jsonb;e jsonb;r jsonb;begin
 r:=public.manager_session(false);if not (r->>'active')::boolean or not private.live() then raise exception 'FAIL fresh sign-in';end if;
 p:=public.walkthrough_page('97000000-0000-0000-0000-000000000003');e:=p->'items'->0;
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_confirmation','confirmed',true));
 if not (r->'entry'->>'confirmed')::boolean then raise exception 'FAIL active walkthrough';end if;
end $$;
reset role;
update private.manager_sessions set last_activity_at=clock_timestamp()-interval '29 minutes' where session_id='97000000-0000-0000-0000-000000000002';
set local role authenticated;
do $$declare before_value numeric;after_value numeric;begin
 before_value:=(public.manager_session(false)->>'idleExpiresAt')::numeric;
 after_value:=(public.manager_session(false)->>'idleExpiresAt')::numeric;
 if before_value<>after_value then raise exception 'FAIL polling reset inactivity';end if;
 if (public.manager_session(true)->>'idleExpiresAt')::numeric<=after_value then raise exception 'FAIL meaningful activity';end if;
end $$;
reset role;
update private.manager_sessions set last_activity_at=clock_timestamp()-interval '30 minutes 1 second' where session_id='97000000-0000-0000-0000-000000000002';
update auth.sessions set refreshed_at=clock_timestamp() where id='97000000-0000-0000-0000-000000000002';
set local role authenticated;
do $$declare denied boolean:=false;begin
 if private.live() or (public.manager_session(false)->>'active')::boolean or (public.manager_session(true)->>'active')::boolean then raise exception 'FAIL idle/refresh/revival';end if;
 if exists(select 1 from public.facilities where id='97000000-0000-0000-0000-000000000003') then raise exception 'FAIL expired RLS access';end if;
 begin perform public.walkthrough_page('97000000-0000-0000-0000-000000000003');exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'FAIL expired protected RPC';end if;
end $$;
reset role;
update auth.sessions set created_at=clock_timestamp()-interval '12 hours 1 second' where id='97000000-0000-0000-0000-000000000002';
update private.manager_sessions set last_activity_at=clock_timestamp() where session_id='97000000-0000-0000-0000-000000000002';
set local role authenticated;
do $$begin
 if private.live() or (public.manager_session(true)->>'active')::boolean then raise exception 'FAIL absolute lifetime';end if;
end $$;
reset role;
do $$begin
 if has_function_privilege('anon','public.manager_session(boolean)','execute') or has_table_privilege('authenticated','private.manager_sessions','select,insert,update,delete') then raise exception 'FAIL session-table permissions';end if;
end $$;
