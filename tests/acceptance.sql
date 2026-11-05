
begin;
insert into auth.users(id,email) values('10000000-0000-0000-0000-000000000001','acceptance-admin@example.invalid'),('10000000-0000-0000-0000-000000000002','acceptance-employee@example.invalid'),('10000000-0000-0000-0000-000000000003','acceptance-other@example.invalid');
insert into public.profiles(id,email,name,role) values('10000000-0000-0000-0000-000000000001','acceptance-admin@example.invalid','Acceptance Admin','admin'),('10000000-0000-0000-0000-000000000002','acceptance-employee@example.invalid','Acceptance Employee','employee'),('10000000-0000-0000-0000-000000000003','acceptance-other@example.invalid','Other Employee','employee');
insert into auth.sessions(id,user_id) values('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002'),('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003');
insert into public.facilities(id,name,identifier) values('30000000-0000-0000-0000-000000000001','Acceptance A','TEST-A'),('30000000-0000-0000-0000-000000000002','Acceptance B','TEST-B');
insert into public.memberships values('10000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001'),('10000000-0000-0000-0000-000000000003','30000000-0000-0000-0000-000000000002');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated","session_id":"20000000-0000-0000-0000-000000000002"}',true);
do $$
declare lid uuid;v int;n int;comb text;denied boolean;typ text;col text;
begin
if (select count(*) from public.facilities)<>1 then raise exception 'FAIL facility isolation';end if;
lid:=public.mutate_lock('{"action":"create","serial":"00N63P8633","combination":"04-05-06","color":"Green","facility_id":"30000000-0000-0000-0000-000000000001"}');
if public.reveal_combination(lid)<>'04-05-06' then raise exception 'FAIL reveal';end if;
if (select serial from public.locks where id=lid)<>'00N63P8633' then raise exception 'FAIL leading zeros';end if;
foreach typ in array array['N','N6','N63','8633','P86','00','n63'] loop
if not exists(select 1 from public.locks where serial ilike '%'||typ||'%') then raise exception 'FAIL search %',typ;end if;end loop;
denied:=false;begin perform public.mutate_lock('{"action":"create","serial":"00n63p8633","combination":"1","color":"Red","facility_id":"30000000-0000-0000-0000-000000000001"}');exception when others then denied:=true;end;
if not denied then raise exception 'FAIL duplicates';end if;
denied:=false;begin perform public.mutate_lock('{"action":"create","serial":"SAME","combination":"1","color":"Red","facility_id":"30000000-0000-0000-0000-000000000002"}');exception when insufficient_privilege then denied:=true;end;
if not denied then raise exception 'FAIL unauthorized write';end if;
v:=1;
foreach col in array array['Red','Black','Green','Other'] loop
perform public.mutate_lock(jsonb_build_object('action','edit','id',lid,'version',v,'serial','00N63P8633','color',col,'notes','test'));v:=v+1;
foreach typ in array array['overlock','vacant','auction'] loop
perform public.mutate_lock(jsonb_build_object('action','assign','id',lid,'version',v,'status',typ,'unit','004A'));v:=v+1;
if (select unit from public.locks where id=lid)<>'004A' then raise exception 'FAIL unit preservation';end if;
denied:=false;begin perform public.mutate_lock(jsonb_build_object('action','assign','id',lid,'version',v,'status','auction','unit','NO'));exception when others then denied:=true;end;
if not denied then raise exception 'FAIL assignment overwrite';end if;
perform public.mutate_lock(jsonb_build_object('action','release','id',lid,'version',v));v:=v+1;
if (select status<>'available' or unit is not null from public.locks where id=lid) then raise exception 'FAIL release';end if;
end loop;end loop;
if (select count(*) from public.assignments where lock_id=lid and released_at is not null)<>12 then raise exception 'FAIL assignment history';end if;
denied:=false;begin perform public.mutate_lock(jsonb_build_object('action','edit','id',lid,'version',1,'serial','00N63P8633','color','Red'));exception when serialization_failure then denied:=true;end;
if not denied then raise exception 'FAIL stale edit';end if;
perform public.mutate_lock(jsonb_build_object('action','edit','id',lid,'version',v,'serial','00N63P8633','color','Green','combination','99-98-97'));v:=v+1;
if public.reveal_combination(lid)<>'99-98-97' then raise exception 'FAIL combination correction';end if;
if exists(select 1 from public.activity where before_values::text like '%04-05-06%' or after_values::text like '%99-98-97%') then raise exception 'FAIL combination leaked to history';end if;
n:=public.import_locks('[{"serial":"IMPORT01","combination":"10-11-12","color":"Black","facility_id":"30000000-0000-0000-0000-000000000001","status":"vacant","unit":"500"},{"serial":"IMPORT02","combination":"01-02-03","color":"Red","facility_id":"30000000-0000-0000-0000-000000000001","status":"missing"}]');
if n<>2 then raise exception 'FAIL import';end if;
denied:=false;begin perform public.import_locks('[{"serial":"ROLLBACK1","combination":"10","color":"Black","facility_id":"30000000-0000-0000-0000-000000000001"},{"serial":"IMPORT01","combination":"10","color":"Red","facility_id":"30000000-0000-0000-0000-000000000001"}]');exception when others then denied:=true;end;
if not denied or exists(select 1 from public.locks where serial='ROLLBACK1') then raise exception 'FAIL atomic import';end if;
if public.validate_import('[{"serial":"import01","facility_id":"30000000-0000-0000-0000-000000000001"}]')='[]'::jsonb then raise exception 'FAIL import duplicate preview';end if;
if (public.inventory_counts('30000000-0000-0000-0000-000000000001')->>'available')::int<>1 then raise exception 'FAIL inventory counts';end if;
denied:=false;begin execute 'select * from private.lock_secrets';exception when insufficient_privilege then denied:=true;end;
if not denied then raise exception 'FAIL private combinations';end if;
denied:=false;begin update public.locks set serial='BYPASS' where id=lid;exception when insufficient_privilege then denied:=true;end;
if not denied then raise exception 'FAIL direct write bypass';end if;
end $$;
reset role;
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"20000000-0000-0000-0000-000000000001"}',true);
set local role authenticated;
do $$ declare lid uuid;begin
if (select count(*) from public.facilities)<>2 then raise exception 'FAIL admin facilities';end if;
lid:=public.mutate_lock('{"action":"create","serial":"00n63p8633","combination":"Other facility","color":"Red","facility_id":"30000000-0000-0000-0000-000000000002"}');
if public.reveal_combination(lid)<>'Other facility' then raise exception 'FAIL admin cross facility reveal';end if;
end $$;
reset role;
select set_config('request.jwt.claims','{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated","session_id":"20000000-0000-0000-0000-000000000002"}',true);
set local role authenticated;
do $$ declare lid uuid;denied boolean:=false;begin
if exists(select 1 from public.locks where facility_id='30000000-0000-0000-0000-000000000002') then raise exception 'FAIL cross facility inventory';end if;
begin perform public.admin_action('{"action":"facility","name":"HACK","identifier":"HACK"}');exception when insufficient_privilege then denied:=true;end;
if not denied then raise exception 'FAIL employee admin action';end if;
end $$;
reset role;
delete from auth.sessions where id='20000000-0000-0000-0000-000000000002';
set local role authenticated;
do $$begin if exists(select 1 from public.locks) then raise exception 'FAIL revoked session retains access';end if;end$$;
reset role;
select 'PASS: facility RLS, admin access, creation, duplicate serials, seven search patterns, 12 color/assignment combinations, unit preservation, release, history, stale edits, reveal/correction, history redaction, atomic import, counts, direct write denial, revoked sessions' as acceptance_result;
rollback;
