-- Execute only in a rolled-back transaction after the session migration.
insert into auth.users(id,email) values('99000000-0000-0000-0000-000000000001','session-starter@example.invalid'),('99000000-0000-0000-0000-000000000002','session-finisher@example.invalid');
insert into public.profiles(id,email,name,role) values('99000000-0000-0000-0000-000000000001','session-starter@example.invalid','Session Starter','employee'),('99000000-0000-0000-0000-000000000002','session-finisher@example.invalid','Session Finisher','employee');
insert into auth.sessions(id,user_id,created_at) values('99000000-0000-0000-0000-000000000011','99000000-0000-0000-0000-000000000001',clock_timestamp()),('99000000-0000-0000-0000-000000000012','99000000-0000-0000-0000-000000000002',clock_timestamp());
insert into public.facilities(id,name,identifier) values('99000000-0000-0000-0000-000000000021','Session QA','SESSION-QA'),('99000000-0000-0000-0000-000000000022','Other Session QA','OTHER-SESSION-QA');
insert into public.memberships values('99000000-0000-0000-0000-000000000001','99000000-0000-0000-0000-000000000021'),('99000000-0000-0000-0000-000000000002','99000000-0000-0000-0000-000000000021');
insert into private.walkthrough_sources values('99000000-0000-0000-0000-000000000021','[{"unitId":"z3","label":"Z3","kind":"occupied","tenantName":"Isolated Fixture"},{"unitId":"001","label":"0001","kind":"occupied","tenantName":"Isolated Fixture"},{"unitId":"a2","label":"A2","kind":"occupied","tenantName":"Isolated Fixture"}]','cubby',clock_timestamp());
select set_config('request.jwt.claims','{"sub":"99000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"99000000-0000-0000-0000-000000000011"}',true);
set local role authenticated;
do $$declare p jsonb;s1 jsonb;s2 jsonb;e jsonb;r jsonb;denied boolean;begin
 perform public.manager_session(false);
 p:=public.walkthrough_page('99000000-0000-0000-0000-000000000021');if p->>'id' is not null or p->'history'<>'[]'::jsonb then raise exception 'FAIL auto-created inspection';end if;
 s1:=public.walkthrough_session('{"action":"new","facilityId":"99000000-0000-0000-0000-000000000021","requestId":"99000000-0000-0000-0000-000000000031"}');
 s2:=public.walkthrough_session('{"action":"new","facilityId":"99000000-0000-0000-0000-000000000021","requestId":"99000000-0000-0000-0000-000000000032"}');
 if s1->>'id'=s2->>'id' or s1->>'startedBy'<>'Session Starter' or s2->>'startedBy'<>'Session Starter' or s1->'items'->0->'expected'->>'label'<>'Z3' or s1->'items'->1->'expected'->>'label'<>'0001' then raise exception 'FAIL independent identity/attribution/route';end if;
 if exists(select 1 from jsonb_array_elements(s2->'items') x(value) where (x.value->>'confirmed')::boolean) then raise exception 'FAIL new session confirmations';end if;
 r:=public.walkthrough_session('{"action":"new","facilityId":"99000000-0000-0000-0000-000000000021","requestId":"99000000-0000-0000-0000-000000000031"}');if r->>'id'<>s1->>'id' or jsonb_array_length(r->'history')<>2 then raise exception 'FAIL idempotent start';end if;
 perform set_config('qa.s1',s1->>'id',true);perform set_config('qa.s2',s2->>'id',true);
 e:=s1->'items'->0;perform public.walkthrough_record(jsonb_build_object('weekId',s1->>'id','entryId',e->>'id','version',e->'version','action','set_confirmation','confirmed',true));
 e:=s1->'items'->1;r:=public.walkthrough_record(jsonb_build_object('weekId',s1->>'id','entryId',e->>'id','version',e->'version','action','set_issue','issue','Door/Latch Damage'));e:=r->'entry';
 if (e->>'confirmed')::boolean then raise exception 'FAIL issue auto-confirmed';end if;
 perform public.walkthrough_record(jsonb_build_object('weekId',s1->>'id','entryId',e->>'id','version',e->'version','action','set_notes','notes','Retain this finding'));
 p:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',(s1->>'id')::uuid);
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','restart','sessionId',s1->>'id','version',p->'sessionVersion'));exception when others then denied:=true;end;if not denied then raise exception 'FAIL restart without confirmation';end if;
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','restart','sessionId',s1->>'id','version',0,'acknowledged',true,'permanent',true));exception when serialization_failure then denied:=true;end;if not denied then raise exception 'FAIL stale management revision';end if;
 p:=public.walkthrough_session(jsonb_build_object('action','restart','sessionId',s1->>'id','version',p->'sessionVersion','acknowledged',true,'permanent',true));
 if exists(select 1 from jsonb_array_elements(p->'items') x(value) where (x.value->>'confirmed')::boolean) or p->'items'->1->>'issue'<>'Door/Latch Damage' or p->'items'->1->>'notes'<>'Retain this finding' or p->'items'->1->>'issueManager'<>'Session Starter' then raise exception 'FAIL restart findings';end if;
 r:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',(s2->>'id')::uuid);if (r->>'inspected')::int<>0 then raise exception 'FAIL cross-session overwrite';end if;
 denied:=false;begin perform public.walkthrough_page('99000000-0000-0000-0000-000000000022',(s1->>'id')::uuid);exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL facility isolation';end if;
end $$;
reset role;
do $$begin
 if not exists(select 1 from private.walkthrough_reset_archive where original_week_id=current_setting('qa.s1')::uuid and reason like 'restart%' and snapshot->'entries' @> '[{"confirmed":true}]') then raise exception 'FAIL restart archive';end if;
 if (select jsonb_array_length(initial_snapshot->'units') from private.walkthrough_weeks where id=current_setting('qa.s1')::uuid)<>3 then raise exception 'FAIL route snapshot';end if;
end $$;
select set_config('request.jwt.claims','{"sub":"99000000-0000-0000-0000-000000000002","role":"authenticated","session_id":"99000000-0000-0000-0000-000000000012"}',true);
set local role authenticated;
do $$declare p jsonb;e jsonb;r jsonb;denied boolean;begin
 perform public.manager_session(false);p:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.s1')::uuid);
 for e in select value from jsonb_array_elements(p->'items') loop perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_confirmation','confirmed',true));end loop;
 perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','action','complete'));
 p:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.s1')::uuid);
 if p->>'status'<>'completed' or p->>'startedBy'<>'Session Starter' or p->>'completedBy'<>'Session Finisher' or not (p->>'historical')::boolean or p->'items'->1->>'issue'<>'Door/Latch Damage' then raise exception 'FAIL completion attribution/history';end if;
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','restart','sessionId',p->>'id','version',p->'sessionVersion','acknowledged',true,'permanent',true));exception when others then denied:=true;end;if not denied then raise exception 'FAIL completed restart';end if;
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','discard','sessionId',p->>'id','version',p->'sessionVersion','acknowledged',true,'permanent',true));exception when others then denied:=true;end;if not denied then raise exception 'FAIL completed discard';end if;
 p:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.s2')::uuid);
 r:=public.walkthrough_session(jsonb_build_object('action','discard','sessionId',p->>'id','version',p->'sessionVersion','acknowledged',true,'permanent',true));
 if r->>'id' is not null or jsonb_array_length(r->'history')<>1 then raise exception 'FAIL discard active choices';end if;
 denied:=false;begin perform public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.s2')::uuid);exception when others then denied:=true;end;if not denied then raise exception 'FAIL discarded resume';end if;
 r:=public.walkthrough_page('99000000-0000-0000-0000-000000000021');if r->>'id' is not null then raise exception 'FAIL automatic next-week creation';end if;
end $$;
reset role;
do $$begin
 if exists(select 1 from private.walkthrough_entries where week_id=current_setting('qa.s2')::uuid) or exists(select 1 from private.walkthrough_weeks where id=current_setting('qa.s2')::uuid) or not exists(select 1 from private.walkthrough_deletions where inspection_id=current_setting('qa.s2')::uuid) then raise exception 'FAIL permanent discard';end if;
end $$;
