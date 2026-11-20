-- A profile is also the identity used by historic inspections and audit records.
-- Only the sign-in relationship is cleared when an Auth user is removed.
alter table public.profiles add column auth_user_id uuid unique references auth.users(id) on delete set null;
update public.profiles set auth_user_id=id;
alter table public.profiles drop constraint profiles_id_fkey;
alter table public.profiles add constraint profile_auth_identity_matches
 check ((auth_user_id is null and not active) or (auth_user_id is not null and auth_user_id=id));

create function private.link_profile_auth_user() returns trigger language plpgsql set search_path='' as $$
begin
  new.auth_user_id:=new.id;
  return new;
end $$;
create trigger link_profile_auth_user before insert on public.profiles
 for each row execute function private.link_profile_auth_user();
revoke all on function private.link_profile_auth_user() from public,anon,authenticated;

alter table private.approved_users add column account_id uuid not null unique default gen_random_uuid();

create or replace function private.list_accounts() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'account_id',a.account_id,'email',a.email,'name',a.name,'role',a.role,'active',a.active,
  'facility_ids',a.facility_ids,'registered',p.id is not null,
  'setup_complete',u.email_confirmed_at is not null and coalesce(u.encrypted_password,'')<>'',
  'invitation_state',i.state,'invitation_sent_at',i.sent_at
 ) order by a.name,a.email)
 from private.approved_users a
 left join auth.users u on lower(u.email)=a.email and u.deleted_at is null
 left join public.profiles p on p.auth_user_id=u.id
 left join private.account_invitations i on i.email=a.email),'[]');
end $$;

create function private.account_email_available() returns boolean language sql stable security definer set search_path='' as $$
 select private.admin() and coalesce((select enabled from private.account_email_settings where id),false)
$$;
create function public.account_email_available() returns boolean language sql stable security invoker set search_path='' as $$
 select private.account_email_available()
$$;

create function private.delete_team_account(target_account_id uuid) returns boolean
language plpgsql security definer set search_path='' set lock_timeout='3s' as $$
declare
  target private.approved_users;
  sign_in_ids uuid[];
  sign_in_id uuid;
begin
  if not private.admin() then raise exception 'Administrator access required' using errcode='42501'; end if;

  -- Serialize with sign-up so a new Auth row cannot slip between lookup and deletion.
  lock table auth.users in share row exclusive mode;
  if not private.admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  select * into target from private.approved_users where account_id=target_account_id for update;
  if not found then
    raise exception 'This account was already removed. Refresh Team access.' using errcode='P0002';
  end if;
  select array_agg(id) into sign_in_ids from auth.users where lower(email)=target.email and deleted_at is null;
  if cardinality(sign_in_ids)>1 or exists(
    select 1 from public.profiles where email=target.email and auth_user_id is distinct from sign_in_ids[1]
  ) then
    raise exception 'Sign-in identity is ambiguous. Contact the project administrator.' using errcode='P0001';
  end if;
  sign_in_id:=sign_in_ids[1];
  if sign_in_id=auth.uid() then
    raise exception 'You cannot delete your own administrator account.' using errcode='42501';
  end if;
  if exists(
    select 1 from private.account_invitations where email=target.email
     and state in ('sending','unknown') and claimed_at>statement_timestamp()-interval '5 minutes'
  ) then
    raise exception 'A setup email is still being processed. Try deleting this account in a few minutes.' using errcode='P0001';
  end if;

  update public.profiles set email='',active=false where id=sign_in_id;
  delete from public.memberships where user_id=sign_in_id;
  delete from private.account_invitations where email=target.email;
  delete from private.approved_users where account_id=target_account_id;
  delete from auth.users where id=sign_in_id;
  insert into public.activity(actor_id,action,before_values)
  values(auth.uid(),'account_deleted',jsonb_build_object(
    'email',target.email,'role',target.role,'account_id',target.account_id,'profile_id',sign_in_id
  ));
  return true;
end $$;
create function public.delete_team_account(target_account_id uuid) returns boolean
language sql security invoker set search_path='' as $$
 select private.delete_team_account(target_account_id)
$$;

revoke all on function private.account_email_available(),public.account_email_available(),
 private.delete_team_account(uuid),public.delete_team_account(uuid) from public,anon,authenticated;
grant execute on function private.account_email_available(),public.account_email_available(),
 private.delete_team_account(uuid),public.delete_team_account(uuid) to authenticated;
