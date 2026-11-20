-- Isolated account, session, and history fixtures. Run inside BEGIN / ROLLBACK.
insert into private.approved_users(account_id,email,name,role)
values
 ('97000000-0000-0000-0000-000000000001','delete-admin@example.invalid','Deletion Admin','admin'),
 ('97000000-0000-0000-0000-000000000002','delete-registered@example.invalid','Deletion Employee','employee'),
 ('97000000-0000-0000-0000-000000000003','delete-unregistered@example.invalid','Pending Employee','employee');
insert into auth.users(id,email,email_confirmed_at) values
 ('97000000-0000-0000-0000-000000000011','delete-admin@example.invalid',clock_timestamp()),
 ('97000000-0000-0000-0000-000000000012','delete-registered@example.invalid',clock_timestamp());
insert into auth.sessions(id,user_id,created_at) values
 ('97000000-0000-0000-0000-000000000021','97000000-0000-0000-0000-000000000011',clock_timestamp()),
 ('97000000-0000-0000-0000-000000000022','97000000-0000-0000-0000-000000000012',clock_timestamp());
insert into public.activity(actor_id,action) values('97000000-0000-0000-0000-000000000012','deletion_fixture_history');

select set_config('request.jwt.claims','{"sub":"97000000-0000-0000-0000-000000000012","role":"authenticated","session_id":"97000000-0000-0000-0000-000000000022"}',true);
set local role authenticated;
do $$begin
 begin
  perform public.delete_team_account('97000000-0000-0000-0000-000000000003');
  raise exception 'Employee was allowed to delete an account';
 exception when insufficient_privilege then null;end;
end $$;
reset role;

select set_config('request.jwt.claims','{"sub":"97000000-0000-0000-0000-000000000011","role":"authenticated","session_id":"97000000-0000-0000-0000-000000000021"}',true);
set local role authenticated;
do $$begin
 begin
  perform public.delete_team_account('97000000-0000-0000-0000-000000000001');
  raise exception 'Administrator was allowed to delete their own account';
 exception when insufficient_privilege then null;end;
 if not public.delete_team_account('97000000-0000-0000-0000-000000000002') then raise exception 'Registered account deletion failed';end if;
 if not public.delete_team_account('97000000-0000-0000-0000-000000000003') then raise exception 'Pending account deletion failed';end if;
end $$;
reset role;

do $$begin
 if has_function_privilege('anon','public.delete_team_account(uuid)','execute') then
  raise exception 'Anonymous callers can execute the delete function';
 end if;
 if exists(select 1 from auth.users where id='97000000-0000-0000-0000-000000000012')
  or exists(select 1 from auth.sessions where id='97000000-0000-0000-0000-000000000022')
  or exists(select 1 from private.approved_users where email in ('delete-registered@example.invalid','delete-unregistered@example.invalid'))
 then raise exception 'Removed access or session still exists';end if;
 if not exists(select 1 from public.activity a join public.profiles p on p.id=a.actor_id
  where a.action='deletion_fixture_history' and p.name='Deletion Employee' and not p.active and p.email='' and p.auth_user_id is null)
 then raise exception 'The historical profile reference was lost';end if;
end $$;

insert into private.approved_users(account_id,email,name,role)
values ('97000000-0000-0000-0000-000000000004','delete-registered@example.invalid','Fresh Employee','employee');
insert into auth.users(id,email,email_confirmed_at)
values ('97000000-0000-0000-0000-000000000014','delete-registered@example.invalid',clock_timestamp());
set local role authenticated;
do $$begin
 begin
  perform public.delete_team_account('97000000-0000-0000-0000-000000000002');
  raise exception 'A stale delete removed a replacement account';
 exception when sqlstate 'P0002' then null;end;
 if (select count(*) from jsonb_array_elements(public.list_accounts()) a
     where a->>'email'='delete-registered@example.invalid' and a->>'account_id'='97000000-0000-0000-0000-000000000004'
      and (a->>'registered')::boolean)<>1
 then raise exception 'Fresh sign-in could not be provisioned with the same email';end if;
end $$;
reset role;
