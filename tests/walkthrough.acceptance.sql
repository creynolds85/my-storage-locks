begin;
insert into auth.users(id,email) values('91000000-0000-0000-0000-000000000001','walk-qa1@example.invalid'),('91000000-0000-0000-0000-000000000002','walk-qa2@example.invalid');
insert into public.profiles(id,email,name,role) values('91000000-0000-0000-0000-000000000001','walk-qa1@example.invalid','Walk QA One','admin'),('91000000-0000-0000-0000-000000000002','walk-qa2@example.invalid','Walk QA Two','employee');
insert into auth.sessions(id,user_id) values('92000000-0000-0000-0000-000000000001','91000000-0000-0000-0000-000000000001'),('92000000-0000-0000-0000-000000000002','91000000-0000-0000-0000-000000000002');
insert into public.facilities(id,name,identifier) values('93000000-0000-0000-0000-000000000001','Walk QA A','WALK-QA-A'),('93000000-0000-0000-0000-000000000002','Walk QA B','WALK-QA-B');
insert into public.memberships values('91000000-0000-0000-0000-000000000002','93000000-0000-0000-0000-000000000001');
insert into private.walkthrough_sources values('93000000-0000-0000-0000-000000000001','[{"unitId":"qa1","label":"10","kind":"occupied","tenantName":"QA Tenant"},{"unitId":"qa2","label":"2","kind":"vacant"},{"unitId":"qa3","label":"3","kind":"overlock"},{"unitId":"qa4","label":"4","kind":"auction","auctionStatus":"LISTED"}]','cubby',now());
select set_config('request.jwt.claims','{"sub":"91000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"92000000-0000-0000-0000-000000000001"}',true);
set local role authenticated;
do $$declare p jsonb;e jsonb;v jsonb;denied boolean;begin
 p:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');
 if p->'items'->0->'expected'->>'label'<>'10' or p->'items'->1->'expected'->>'label'<>'2' then raise exception 'FAIL route order';end if;
 if (p->'items'->1->'expected'->>'missing')::boolean then raise exception 'FAIL unknown vacant policy';end if;
 if not (p->'items'->2->'expected'->>'missing')::boolean or not (p->'items'->3->'expected'->>'missing')::boolean then raise exception 'FAIL missing overlock/auction';end if;
 perform public.walkthrough_policy('93000000-0000-0000-0000-000000000001',true,'auction');
 p:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');
 if not (p->'items'->1->'expected'->>'missing')::boolean then raise exception 'FAIL required vacant lock';end if;
 perform set_config('walk.qa.week',p->>'id',true);e:=p->'items'->0;
 perform set_config('walk.qa.entry',e->>'id',true);
 denied:=false;begin perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','action','complete'));exception when others then denied:=true;end;if not denied then raise exception 'FAIL incomplete finalization';end if;
 perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','result','confirmed'));
 denied:=false;begin perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','result','issue','issue','Moved Out'));exception when serialization_failure then denied:=true;end;if not denied then raise exception 'FAIL concurrent overwrite';end if;
 p:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');
 if p->'items'->0->>'result'<>'confirmed' or p->'items'->0->>'manager'<>'Walk QA One' then raise exception 'FAIL immediate persistence/attribution';end if;
 if p->'items'->0->'expected'->>'label'<>'10' then raise exception 'FAIL completed unit reordered';end if;
 for e in select value from jsonb_array_elements(p->'items') loop
  perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','result','issue','issue','Other','notes','Fixture only'));
 end loop;
 perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','action','complete'));
 v:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');if v->>'completedAt' is null or v->>'id'<>p->>'id' then raise exception 'FAIL completed resume';end if;
 if jsonb_array_length(public.automation_dashboard('93000000-0000-0000-0000-000000000001')->'items')<>7 then raise exception 'FAIL issue and missing action deduplication';end if;
 e:=v->'items'->0;
 perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','result','confirmed'));
 v:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');if v->>'completedAt' is not null then raise exception 'FAIL corrected inspection not reopened';end if;
 denied:=false;begin perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',99,'result','issue','issue','Unapproved Category'));exception when others then denied:=true;end;if not denied then raise exception 'FAIL issue allowlist';end if;
end $$;
reset role;
-- Two managers share the same record, but stale revisions cannot win.
select set_config('request.jwt.claims','{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated","session_id":"92000000-0000-0000-0000-000000000002"}',true);
set local role authenticated;
do $$declare p jsonb;e jsonb;denied boolean;begin
 p:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');e:=p->'items'->0;
 perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','result','confirmed'));
 denied:=false;begin perform public.walkthrough_page('93000000-0000-0000-0000-000000000002');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL cross-facility scope';end if;
 denied:=false;begin perform public.walkthrough_policy('93000000-0000-0000-0000-000000000001',false,'none');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL employee policy edit';end if;
 denied:=false;begin perform public.walkthrough_source_save('invalid','93000000-0000-0000-0000-000000000001','{}');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL forged source';end if;
end $$;
reset role;
do $$begin
 if (select count(*) from private.walkthrough_events where week_id=current_setting('walk.qa.week')::uuid and actor_id='91000000-0000-0000-0000-000000000002')<>1 then raise exception 'FAIL second manager attribution';end if;
 if (select count(*) from public.action_items where facility_id='93000000-0000-0000-0000-000000000001' and kind='walkthrough_issue')<>4 then raise exception 'FAIL issue count';end if;
 if exists(select 1 from public.assignments where facility_id='93000000-0000-0000-0000-000000000001') or exists(select 1 from public.locks where facility_id='93000000-0000-0000-0000-000000000001') then raise exception 'FAIL inventory modified';end if;
end $$;
-- Stale sources prevent confirmation; each new calendar week keeps prior results.
update private.walkthrough_sources set observed_at=now()-interval '10 minutes' where facility_id='93000000-0000-0000-0000-000000000001';
set local role authenticated;
do $$declare p jsonb;e jsonb;denied boolean;begin
 p:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');e:=p->'items'->0;
 if not (p->>'stale')::boolean then raise exception 'FAIL stale indication';end if;
 denied:=false;begin perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','result','confirmed'));exception when others then denied:=true;end;if not denied then raise exception 'FAIL stale confirmation';end if;
end $$;
reset role;
update private.walkthrough_sources set observed_at=now() where facility_id='93000000-0000-0000-0000-000000000001';
update private.walkthrough_weeks set week_start=week_start-7 where id=current_setting('walk.qa.week')::uuid;
set local role authenticated;
do $$declare p jsonb;begin
 p:=public.walkthrough_page('93000000-0000-0000-0000-000000000001');if p->>'id'=current_setting('walk.qa.week') or jsonb_array_length(p->'history')<>2 or p->'items'->0->>'result'<>'unchecked' then raise exception 'FAIL weekly rollover/history';end if;
 if not (public.walkthrough_page('93000000-0000-0000-0000-000000000001',current_setting('walk.qa.week')::uuid)->>'historical')::boolean then raise exception 'FAIL historical read';end if;
end $$;
reset role;
select set_config('request.jwt.claims','{}',true);
set local role anon;
do $$declare denied boolean:=false;begin
 begin perform public.walkthrough_page('93000000-0000-0000-0000-000000000001');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL anonymous read';end if;
end $$;
reset role;
rollback;
select 'PASS: walkthrough persistence, source safeguards, six issues, deduplicated tasks, weekly rollover, attribution, optimistic concurrency and facility authorization; all fixtures rolled back' as result;
