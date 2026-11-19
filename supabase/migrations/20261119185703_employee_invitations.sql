-- Account email delivery is enabled only after production SMTP is verified.
create table private.account_email_settings(id boolean primary key default true check(id),enabled boolean not null default false);
insert into private.account_email_settings(id) values(true);
alter table private.account_email_settings enable row level security;
revoke all on private.account_email_settings from public,anon,authenticated;
create table private.account_invitations(
 email text primary key references private.approved_users(email),attempt_id uuid not null,
 actor_id uuid not null references public.profiles(id),state text not null check(state in ('sending','sent','failed','unknown')),
 kind text not null check(kind in ('invite','confirmation','recovery')),claimed_at timestamptz not null,
 sent_at timestamptz,error_code text
);
alter table private.account_invitations enable row level security;
revoke all on private.account_invitations from public,anon,authenticated;
create function private.account_invitation_claim(recipient text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a private.approved_users; u auth.users; previous private.account_invitations; attempt uuid:=extensions.gen_random_uuid(); email_kind text;
begin
 if not private.admin() then raise exception 'Administrator access required' using errcode='42501';end if;
 if not coalesce((select enabled from private.account_email_settings where id),false) then raise exception 'Account email delivery is not configured' using errcode='P0001';end if;
 select * into a from private.approved_users where email=lower(trim(recipient)) for update;
 if not found or not a.active then raise exception 'Choose an active authorized account' using errcode='42501';end if;
 select * into previous from private.account_invitations where email=a.email;
 if previous.claimed_at>clock_timestamp()-interval '60 seconds' or (previous.state in ('sending','unknown') and previous.claimed_at>clock_timestamp()-interval '5 minutes') then raise exception 'Please wait before requesting another setup email' using errcode='P0002';end if;
 select * into u from auth.users where lower(email)=a.email;
 if u.id is not null then
  if u.deleted_at is not null or u.banned_until>clock_timestamp() then raise exception 'Account is unavailable' using errcode='42501';end if;
  -- The approved access record remains the authority if a user registered first.
  insert into public.profiles(id,email,name,role,active) values(u.id,a.email,a.name,a.role,a.active)
   on conflict(id) do update set name=excluded.name,role=excluded.role,active=excluded.active;
  delete from public.memberships where user_id=u.id;
  insert into public.memberships(user_id,facility_id) select u.id,unnest(a.facility_ids);
 end if;
 email_kind:=case when u.id is null or (u.invited_at is not null and u.email_confirmed_at is null) then 'invite' when u.email_confirmed_at is null then 'confirmation' else 'recovery' end;
 insert into private.account_invitations(email,attempt_id,actor_id,state,kind,claimed_at) values(a.email,attempt,auth.uid(),'sending',email_kind,clock_timestamp())
 on conflict(email) do update set attempt_id=excluded.attempt_id,actor_id=excluded.actor_id,state=excluded.state,kind=excluded.kind,claimed_at=excluded.claimed_at,error_code=null;
 return jsonb_build_object('attemptId',attempt,'email',a.email,'kind',email_kind);
end $$;
create function public.account_invitation_claim(recipient text) returns jsonb language sql security invoker set search_path='' as $$select private.account_invitation_claim(recipient)$$;
create function private.account_invitation_finish(p jsonb) returns boolean language plpgsql security definer set search_path='' as $$
declare invitation private.account_invitations; result_state text:=p->>'state'; safe_code text;
begin
 if not private.admin() then raise exception 'Administrator access required' using errcode='42501';end if;
 if result_state not in ('sent','failed','unknown') then raise exception 'Invalid email outcome';end if;
 safe_code:=case when p->>'code' in ('over_email_send_rate_limit','over_email_send_rate_limit_user','email_address_not_authorized','email_exists','email_send_failed','email_outcome_unknown') then p->>'code' else null end;
 select * into invitation from private.account_invitations where attempt_id=(p->>'attemptId')::uuid and actor_id=auth.uid() for update;
 if not found or invitation.state<>'sending' then raise exception 'Email attempt is no longer pending';end if;
 update private.account_invitations set state=result_state,error_code=safe_code,sent_at=case when result_state='sent' then clock_timestamp() else sent_at end where email=invitation.email;
 insert into public.activity(actor_id,action,after_values) values(auth.uid(),'account_email_'||result_state,jsonb_build_object('email',invitation.email,'kind',invitation.kind,'errorCode',safe_code));
 return true;
end $$;
create function public.account_invitation_finish(p jsonb) returns boolean language sql security invoker set search_path='' as $$select private.account_invitation_finish(p)$$;
revoke all on function private.account_invitation_claim(text),public.account_invitation_claim(text),private.account_invitation_finish(jsonb),public.account_invitation_finish(jsonb) from public,anon;
grant execute on function private.account_invitation_claim(text),public.account_invitation_claim(text),private.account_invitation_finish(jsonb),public.account_invitation_finish(jsonb) to authenticated;
create or replace function private.list_accounts() returns jsonb language plpgsql security definer set search_path='' as $$
begin if not private.admin() then raise exception 'Administrator access required';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('email',a.email,'name',a.name,'role',a.role,'active',a.active,'facility_ids',a.facility_ids,'registered',p.id is not null,
 'setup_complete',u.email_confirmed_at is not null and coalesce(u.encrypted_password,'')<>'','invitation_state',i.state,'invitation_sent_at',i.sent_at) order by a.name)
 from private.approved_users a left join public.profiles p on p.email=a.email left join auth.users u on lower(u.email)=a.email left join private.account_invitations i on i.email=a.email),'[]');
end $$;
