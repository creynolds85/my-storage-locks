-- Isolated invitation authorization fixtures. Always run inside BEGIN / ROLLBACK.
insert into auth.users(id,email,email_confirmed_at,encrypted_password) values
 ('96000000-0000-0000-0000-000000000001','invite-admin@example.invalid',clock_timestamp(),'fixture'),
 ('96000000-0000-0000-0000-000000000002','invite-employee@example.invalid',clock_timestamp(),'fixture'),
 ('96000000-0000-0000-0000-000000000003','invite-pending@example.invalid',null,'fixture'),
 ('96000000-0000-0000-0000-000000000004','invite-established@example.invalid',clock_timestamp(),'fixture');
insert into public.profiles(id,email,name,role) values
 ('96000000-0000-0000-0000-000000000001','invite-admin@example.invalid','Invite Admin','admin'),
 ('96000000-0000-0000-0000-000000000002','invite-employee@example.invalid','Invite Employee','employee');
insert into auth.sessions(id,user_id,created_at) values
 ('96000000-0000-0000-0000-000000000011','96000000-0000-0000-0000-000000000001',clock_timestamp()),
 ('96000000-0000-0000-0000-000000000012','96000000-0000-0000-0000-000000000002',clock_timestamp());
insert into public.facilities(id,name,identifier) values('96000000-0000-0000-0000-000000000021','Invitation QA','INVITATION-QA');
insert into private.approved_users(email,name,role,active,facility_ids) values
 ('invite-new@example.invalid','New QA','employee',true,array['96000000-0000-0000-0000-000000000021'::uuid]),
 ('invite-inactive@example.invalid','Inactive QA','employee',false,'{}'),
 ('invite-pending@example.invalid','Pending QA','employee',true,'{}'),
 ('invite-established@example.invalid','Established QA','employee',true,'{}');
select set_config('request.jwt.claims','{"sub":"96000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"96000000-0000-0000-0000-000000000011"}',true);
set local role authenticated;
select public.manager_session(false);
do $$declare denied boolean:=false;begin
 begin perform public.account_invitation_claim('invite-new@example.invalid');exception when sqlstate 'P0001' then denied:=true;end;
 if not denied then raise exception 'FAIL email delivery was not gated';end if;
end $$;
reset role;
update private.account_email_settings set enabled=true where id;
set local role authenticated;
do $$declare denied boolean;c jsonb;found_account jsonb;begin
 c:=public.account_invitation_claim(' INVITE-NEW@EXAMPLE.INVALID ');
 if c->>'kind'<>'invite' or c->>'email'<>'invite-new@example.invalid' then raise exception 'FAIL new invitation';end if;
 if not public.account_invitation_finish(jsonb_build_object('attemptId',c->>'attemptId','state','sent')) then raise exception 'FAIL sent outcome';end if;
 denied:=false;begin perform public.account_invitation_claim('invite-new@example.invalid');exception when sqlstate 'P0002' then denied:=true;end;if not denied then raise exception 'FAIL duplicate send';end if;
 denied:=false;begin perform public.account_invitation_claim('invite-inactive@example.invalid');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL inactive recipient';end if;
 denied:=false;begin perform public.account_invitation_claim('not-authorized@example.invalid');exception when insufficient_privilege then denied:=true;end;if not denied then raise exception 'FAIL unauthorized recipient';end if;
 c:=public.account_invitation_claim('invite-pending@example.invalid');if c->>'kind'<>'confirmation' then raise exception 'FAIL pending signup branch';end if;
 perform public.account_invitation_finish(jsonb_build_object('attemptId',c->>'attemptId','state','failed','code','over_email_send_rate_limit'));
 c:=public.account_invitation_claim('invite-established@example.invalid');if c->>'kind'<>'recovery' then raise exception 'FAIL established branch';end if;
 perform public.account_invitation_finish(jsonb_build_object('attemptId',c->>'attemptId','state','unknown','code','email_outcome_unknown'));
 select value into found_account from jsonb_array_elements(public.list_accounts()) where value->>'email'='invite-established@example.invalid';
 if not (found_account->>'setup_complete')::boolean or found_account->>'invitation_state'<>'unknown' or found_account ? 'encrypted_password' then raise exception 'FAIL safe account summary';end if;
end $$;
reset role;
do $$begin
 if not exists(select 1 from public.activity where actor_id='96000000-0000-0000-0000-000000000001' and action='account_email_sent') then raise exception 'FAIL email audit';end if;
 if not exists(select 1 from public.profiles where id='96000000-0000-0000-0000-000000000003' and role='employee' and active) then raise exception 'FAIL preexisting registration provisioning';end if;
 if has_table_privilege('authenticated','private.account_invitations','select') or has_function_privilege('anon','public.account_invitation_claim(text)','execute') then raise exception 'FAIL email permissions';end if;
end $$;
select set_config('request.jwt.claims','{"sub":"96000000-0000-0000-0000-000000000002","role":"authenticated","session_id":"96000000-0000-0000-0000-000000000012"}',true);
set local role authenticated;
select public.manager_session(false);
do $$declare denied boolean:=false;begin
 begin perform public.account_invitation_claim('invite-new@example.invalid');exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'FAIL employee invitation';end if;
end $$;
reset role;
update auth.sessions set created_at=clock_timestamp()-interval '13 hours' where id='96000000-0000-0000-0000-000000000011';
select set_config('request.jwt.claims','{"sub":"96000000-0000-0000-0000-000000000001","role":"authenticated","session_id":"96000000-0000-0000-0000-000000000011"}',true);
set local role authenticated;
do $$declare denied boolean:=false;begin
 begin perform public.account_invitation_claim('invite-new@example.invalid');exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'FAIL expired administrator';end if;
end $$;
reset role;
