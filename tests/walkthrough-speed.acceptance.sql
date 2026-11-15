begin;
insert into auth.users(id,email) values('95000000-0000-0000-0000-000000000001','walk-speed@example.invalid');
insert into public.profiles(id,email,name,role) values('95000000-0000-0000-0000-000000000001','walk-speed@example.invalid','Walk Speed Fixture','employee');
insert into auth.sessions(id,user_id) values('95000000-0000-0000-0000-000000000002','95000000-0000-0000-0000-000000000001');
insert into public.facilities(id,name,identifier) values('95000000-0000-0000-0000-000000000003','Walk Speed Fixture','WALK-SPEED-QA');
insert into public.memberships values('95000000-0000-0000-0000-000000000001','95000000-0000-0000-0000-000000000003');
insert into private.walkthrough_sources values('95000000-0000-0000-0000-000000000003','[{"unitId":"speed1","label":"3214","kind":"overlock","tenantName":"Fixture Tenant"},{"unitId":"speed2","label":"2","kind":"occupied","tenantName":"Fixture Two"},{"unitId":"speed3","label":"3","kind":"vacant"},{"unitId":"speed4","label":"4","kind":"auction","auctionStatus":"LISTED"}]','cubby',now());
select set_config('request.jwt.claims','{"sub":"95000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"95000000-0000-0000-0000-000000000002"}',true);
set local role authenticated;
do $$declare p jsonb;e jsonb;r jsonb;eid text;version_before int;denied boolean;begin
 p:=public.walkthrough_page('95000000-0000-0000-0000-000000000003');e:=p->'items'->0;eid:=e->>'id';
 perform set_config('speed.week',p->>'id',true);perform set_config('speed.entry',eid,true);
 -- Issue first, then confirm: both persist and the task remains open.
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',e->'version','action','set_issue','issue','Door/Latch Damage'));
 e:=r->'entry';r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',e->'version','action','set_confirmation','confirmed',true));e:=r->'entry';
 if not (e->>'confirmed')::boolean or e->>'issue'<>'Door/Latch Damage' or r ? 'items' then raise exception 'FAIL independent issue-first / targeted response';end if;
 if jsonb_array_length((select jsonb_agg(x) from jsonb_array_elements(public.automation_dashboard('95000000-0000-0000-0000-000000000003')->'items') x where x->>'kind'='walkthrough_issue'))<>1 then raise exception 'FAIL task disappeared on confirmation';end if;
 -- Notes and Undo change neither the issue nor its task.
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',e->'version','action','set_notes','notes','Fixture damage detail'));e:=r->'entry';
 if not (e->>'confirmed')::boolean or e->>'issue'<>'Door/Latch Damage' then raise exception 'FAIL notes independence';end if;
 version_before:=(e->>'version')::int;
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',version_before,'action','set_confirmation','confirmed',false));e:=r->'entry';
 if (e->>'confirmed')::boolean or e->>'issue'<>'Door/Latch Damage' or e->>'notes'<>'Fixture damage detail' then raise exception 'FAIL Undo erased independent data';end if;
 denied:=false;begin perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',version_before,'action','set_confirmation','confirmed',true));exception when serialization_failure then denied:=true;end;if not denied then raise exception 'FAIL stale Undo revision';end if;
 -- Reconfirm and repeat issue save: no duplicates, including legacy open tabs.
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',e->'version','action','set_confirmation','confirmed',true));e:=r->'entry';
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',e->'version','action','set_issue','issue','Door/Latch Damage'));e:=r->'entry';
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',eid,'version',e->'version','result','confirmed'));e:=r->'entry';
 if e->>'issue'<>'Door/Latch Damage' then raise exception 'FAIL legacy confirm erased issue';end if;
 -- Confirmation first, then issue; clearing issue must keep the confirmation.
 e:=p->'items'->1;
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_confirmation','confirmed',true));e:=r->'entry';
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_issue','issue','Other'));e:=r->'entry';
 if not (e->>'confirmed')::boolean or e->>'issue'<>'Other' then raise exception 'FAIL confirm-first independence';end if;
 r:=public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_issue','issue',null));e:=r->'entry';
 if not (e->>'confirmed')::boolean or e->>'issue' is not null then raise exception 'FAIL clearing issue erased confirmation';end if;
 -- Resume preserves the source sequence and both observations.
 p:=public.walkthrough_page('95000000-0000-0000-0000-000000000003');e:=p->'items'->0;
 if p->'items'->0->'expected'->>'label'<>'3214' or not (e->>'confirmed')::boolean or e->>'issue'<>'Door/Latch Damage' or e->>'confirmedManager'<>'Walk Speed Fixture' or e->>'issueManager'<>'Walk Speed Fixture' then raise exception 'FAIL persistence/order/attribution';end if;
 if (select count(*) from jsonb_array_elements(public.automation_dashboard('95000000-0000-0000-0000-000000000003')->'items') x where x->>'kind'='walkthrough_issue')<>1 then raise exception 'FAIL unresolved action duplication';end if;
 -- The final completion still accepts documented exceptions and confirmed units.
 for e in select value from jsonb_array_elements(p->'items') loop
  if not (e->>'confirmed')::boolean then perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','entryId',e->>'id','version',e->'version','action','set_issue','issue','Other'));end if;
 end loop;
 perform public.walkthrough_record(jsonb_build_object('weekId',p->>'id','action','complete'));
end $$;
reset role;
-- Historical access and source changes preserve issue observations without trusting old confirmations.
update private.walkthrough_sources set units=jsonb_set(units,'{0,tenantName}','"Changed fixture tenant"') where facility_id='95000000-0000-0000-0000-000000000003';
set local role authenticated;
do $$declare p jsonb;e jsonb;begin
 p:=public.walkthrough_page('95000000-0000-0000-0000-000000000003');e:=p->'items'->0;
 if (e->>'confirmed')::boolean or e->>'issue'<>'Door/Latch Damage' then raise exception 'FAIL source change erased issue or kept old confirmation';end if;
end $$;
reset role;
update private.walkthrough_weeks set week_start=week_start-7 where id=current_setting('speed.week')::uuid;
set local role authenticated;
do $$declare p jsonb;begin
 p:=public.walkthrough_page('95000000-0000-0000-0000-000000000003',current_setting('speed.week')::uuid);
 if not (p->>'historical')::boolean or p->'items'->0->>'issue'<>'Door/Latch Damage' then raise exception 'FAIL previous inspection access';end if;
end $$;
reset role;
rollback;
select 'PASS: independent observations in either order, targeted saves, Undo, issue task retention/deduplication, persistence, attribution and previous inspection access; fixtures rolled back' as result;
