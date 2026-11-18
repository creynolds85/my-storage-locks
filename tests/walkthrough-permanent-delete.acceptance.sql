-- Execute only in a rolled-back transaction after the session migration.
insert into auth.users(id,email) values('99000000-0000-0000-0000-000000000001','session-starter@example.invalid'),('99000000-0000-0000-0000-000000000002','session-finisher@example.invalid');
insert into public.profiles(id,email,name,role) values('99000000-0000-0000-0000-000000000001','session-starter@example.invalid','Session Starter','employee'),('99000000-0000-0000-0000-000000000002','session-finisher@example.invalid','Session Finisher','employee');
insert into auth.sessions(id,user_id,created_at) values('99000000-0000-0000-0000-000000000011','99000000-0000-0000-0000-000000000001',clock_timestamp()),('99000000-0000-0000-0000-000000000012','99000000-0000-0000-0000-000000000002',clock_timestamp());
insert into public.facilities(id,name,identifier) values('99000000-0000-0000-0000-000000000021','Session QA','SESSION-QA'),('99000000-0000-0000-0000-000000000022','Other Session QA','OTHER-SESSION-QA');
insert into public.memberships values('99000000-0000-0000-0000-000000000001','99000000-0000-0000-0000-000000000021'),('99000000-0000-0000-0000-000000000002','99000000-0000-0000-0000-000000000021');
insert into private.walkthrough_sources values('99000000-0000-0000-0000-000000000021','[{"unitId":"z3","label":"Z3","kind":"occupied","tenantName":"Isolated Fixture"},{"unitId":"001","label":"0001","kind":"occupied","tenantName":"Isolated Fixture"},{"unitId":"a2","label":"A2","kind":"occupied","tenantName":"Isolated Fixture"}]','cubby',clock_timestamp());
select set_config('request.jwt.claims','{"sub":"99000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"99000000-0000-0000-0000-000000000011"}',true);
set local role authenticated;

do $$declare s1 jsonb;s2 jsonb;e jsonb;r jsonb;denied boolean;begin
 perform public.manager_session(false);
 s1:=public.walkthrough_session('{"action":"new","facilityId":"99000000-0000-0000-0000-000000000021","requestId":"99000000-0000-0000-0000-000000000031"}');
 s2:=public.walkthrough_session('{"action":"new","facilityId":"99000000-0000-0000-0000-000000000021","requestId":"99000000-0000-0000-0000-000000000032"}');
 perform set_config('qa.delete_id',s1->>'id',true);perform set_config('qa.survivor_id',s2->>'id',true);
 e:=s1->'items'->0;r:=public.walkthrough_record(jsonb_build_object('weekId',s1->>'id','entryId',e->>'id','version',e->'version','action','set_issue','issue','Other'));e:=r->'entry';
 r:=public.walkthrough_record(jsonb_build_object('weekId',s1->>'id','entryId',e->>'id','version',e->'version','action','set_notes','notes','Inspection-owned note to delete'));e:=r->'entry';
 perform public.walkthrough_record(jsonb_build_object('weekId',s1->>'id','entryId',e->>'id','version',e->'version','action','set_confirmation','confirmed',true));
 s1:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',(s1->>'id')::uuid);
 -- A restart creates a prior-state archive. Deletion must also purge this recoverable copy.
 s1:=public.walkthrough_session(jsonb_build_object('action','restart','sessionId',s1->>'id','version',s1->'sessionVersion','acknowledged',true,'permanent',true));
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','discard','sessionId',s1->>'id','version',s1->'sessionVersion'));exception when others then denied:=true;end;if not denied then raise exception 'FAIL deletion without acknowledgment';end if;
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','discard','sessionId',s1->>'id','version',s1->'sessionVersion','acknowledged',true));exception when others then denied:=true;end;if not denied then raise exception 'FAIL old client can permanently discard without deletion warning';end if;
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','discard','sessionId',s1->>'id','version',0,'acknowledged',true,'permanent',true));exception when serialization_failure then denied:=true;end;if not denied then raise exception 'FAIL stale deletion revision';end if;
end $$;
reset role;
-- Existing independent operational records must survive inspection deletion.
select set_config('qa.independent_hash',(select md5(coalesce(string_agg(to_jsonb(a)::text,',' order by id),'')) from public.action_items a),true);
set local role authenticated;
do $$declare s1 jsonb;r jsonb;begin
 s1:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.delete_id')::uuid);
 r:=public.walkthrough_session(jsonb_build_object('action','discard','sessionId',s1->>'id','version',s1->'sessionVersion','acknowledged',true,'permanent',true));
 if r->>'id'<>current_setting('qa.survivor_id') or jsonb_array_length(r->'history')<>1 or r->'items'->0->>'confirmed'<>'false' then raise exception 'FAIL unrelated session selection/persistence';end if;
end $$;
reset role;
do $$begin
 if exists(select 1 from private.walkthrough_weeks where id=current_setting('qa.delete_id')::uuid)
 or exists(select 1 from private.walkthrough_entries where week_id=current_setting('qa.delete_id')::uuid)
 or exists(select 1 from private.walkthrough_events where week_id=current_setting('qa.delete_id')::uuid)
 or exists(select 1 from private.walkthrough_reset_archive where original_week_id=current_setting('qa.delete_id')::uuid) then raise exception 'FAIL recoverable deleted inspection remains';end if;
 if not exists(select 1 from private.walkthrough_deletions where inspection_id=current_setting('qa.delete_id')::uuid and deleted_by='99000000-0000-0000-0000-000000000001' and reason='manager_discard') then raise exception 'FAIL minimal deletion audit';end if;
 if (select md5(coalesce(string_agg(to_jsonb(a)::text,',' order by id),'')) from public.action_items a)<>current_setting('qa.independent_hash') then raise exception 'FAIL shared operational record changed';end if;
 if exists(select 1 from information_schema.role_table_grants where table_schema='private' and table_name='walkthrough_deletions' and grantee in ('anon','authenticated','PUBLIC')) then raise exception 'FAIL deletion audit exposed';end if;
end $$;
select set_config('request.jwt.claims','{"sub":"99000000-0000-0000-0000-000000000002","role":"authenticated","session_id":"99000000-0000-0000-0000-000000000012"}',true);
set local role authenticated;
do $$declare p jsonb;e jsonb;denied boolean;begin
 perform public.manager_session(false);
 denied:=false;begin perform public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.delete_id')::uuid);exception when others then denied:=true;end;if not denied then raise exception 'FAIL deleted session still readable';end if;
 denied:=false;begin perform public.walkthrough_record(jsonb_build_object('weekId',current_setting('qa.delete_id'),'action','complete'));exception when others then denied:=true;end;if not denied then raise exception 'FAIL another manager can modify deleted session';end if;
 denied:=false;begin perform private.walkthrough_delete_owned(current_setting('qa.survivor_id')::uuid,auth.uid(),'manager_discard');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL private delete helper exposed';end if;
 p:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.survivor_id')::uuid);
 for e in select value from jsonb_array_elements(p->'items') loop perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_confirmation','confirmed',true));end loop;
 perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','action','complete'));
 p:=public.walkthrough_page('99000000-0000-0000-0000-000000000021',current_setting('qa.survivor_id')::uuid);
 denied:=false;begin perform public.walkthrough_session(jsonb_build_object('action','discard','sessionId',p->>'id','version',p->'sessionVersion','acknowledged',true,'permanent',true));exception when others then denied:=true;end;if not denied then raise exception 'FAIL completed inspection deletion';end if;
 if p->>'status'<>'completed' or p->>'completedBy'<>'Session Finisher' then raise exception 'FAIL completed inspection persistence';end if;
end $$;
select set_config('request.jwt.claims','{"sub":"99000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"99000000-0000-0000-0000-000000000011"}',true);
do $$declare denied boolean;begin
 denied:=false;begin perform public.walkthrough_session('{"action":"new","facilityId":"99000000-0000-0000-0000-000000000021","requestId":"99000000-0000-0000-0000-000000000031"}');exception when others then denied:=true;end;if not denied then raise exception 'FAIL retried New resurrected deleted inspection';end if;
end $$;
reset role;
