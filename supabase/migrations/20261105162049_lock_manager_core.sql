
create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
create table public.profiles(id uuid primary key references auth.users on delete cascade,email text not null,name text not null,role text not null check(role in ('admin','employee')),active boolean not null default true,created_at timestamptz not null default now());
create table public.facilities(id uuid primary key default gen_random_uuid(),name text not null check(length(trim(name)) between 1 and 150),identifier text not null check(length(trim(identifier)) between 1 and 60),address text,active boolean not null default true,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create unique index facility_identifier_unique on public.facilities(lower(identifier));
create table public.memberships(user_id uuid references public.profiles on delete cascade,facility_id uuid references public.facilities,primary key(user_id,facility_id));
create table private.approved_users(email text primary key,name text not null,role text not null check(role in ('admin','employee')),active boolean not null default true,facility_ids uuid[] not null default '{}');
-- Bootstrap the first administrator through an authorized database operation; never grant roles from user metadata.
create table public.locks(id uuid primary key default gen_random_uuid(),serial text not null check(serial ~ '^[A-Za-z0-9]+$' and length(serial)<=100),color text not null check(color in ('Red','Black','Green','Other')),facility_id uuid not null references public.facilities,status text not null default 'available' check(status in ('available','overlock','vacant','auction','missing','retired')),unit text,notes text not null default '',created_at timestamptz not null default now(),updated_at timestamptz not null default now(),last_assigned_at timestamptz,last_assigned_by uuid references public.profiles,version int not null default 1,check((status in ('overlock','vacant','auction') and nullif(trim(unit),'') is not null) or (status not in ('overlock','vacant','auction') and unit is null)));
create unique index lock_serial_facility_unique on public.locks(facility_id,lower(serial));
create index lock_serial_search on public.locks using gin(lower(serial) extensions.gin_trgm_ops);
create index lock_facility_status on public.locks(facility_id,status);
create table private.encryption_key(id boolean primary key default true check(id),value text not null);
insert into private.encryption_key(value) values(encode(extensions.gen_random_bytes(32),'hex'));
create table private.lock_secrets(lock_id uuid primary key references public.locks,encrypted bytea not null);
create table public.assignments(id uuid primary key default gen_random_uuid(),lock_id uuid not null references public.locks,facility_id uuid not null references public.facilities,unit text not null,type text not null check(type in ('overlock','vacant','auction')),assigned_by uuid not null references public.profiles,assigned_at timestamptz not null default now(),released_by uuid references public.profiles,released_at timestamptz);
create unique index one_active_assignment on public.assignments(lock_id) where released_at is null;
create index assignment_facility_history on public.assignments(facility_id,assigned_at desc);
create table public.activity(id uuid primary key default gen_random_uuid(),lock_id uuid references public.locks,facility_id uuid references public.facilities,actor_id uuid references public.profiles,action text not null,before_values jsonb,after_values jsonb,created_at timestamptz not null default now());
create index activity_facility_time on public.activity(facility_id,created_at desc);
create function private.live() returns boolean language sql stable security definer set search_path='' as $$
select auth.uid() is not null and exists(select 1 from auth.sessions s where s.id::text=auth.jwt()->>'session_id' and s.user_id=auth.uid() and (s.not_after is null or s.not_after>now())) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active)
$$;
create function private.admin() returns boolean language sql stable security definer set search_path='' as $$
select private.live() and exists(select 1 from public.profiles where id=auth.uid() and role='admin')
$$;
create function private.can_access(f uuid) returns boolean language sql stable security definer set search_path='' as $$
select private.live() and (private.admin() or exists(select 1 from public.memberships m join public.facilities f1 on f1.id=m.facility_id where m.user_id=auth.uid() and m.facility_id=f and f1.active))
$$;
create function private.require_access(f uuid) returns void language plpgsql security definer set search_path='' as $$
begin if not private.can_access(f) then raise exception 'Facility access denied' using errcode='42501';end if;end
$$;
create function private.on_signup() returns trigger language plpgsql security definer set search_path='' as $$
declare a private.approved_users;
begin
select * into a from private.approved_users where email=lower(new.email) and active;
if found then
insert into public.profiles(id,email,name,role) values(new.id,lower(new.email),a.name,a.role);
insert into public.memberships(user_id,facility_id) select new.id,unnest(a.facility_ids);
end if;
return new;end
$$;
create trigger provision_approved_user after insert on auth.users for each row execute function private.on_signup();
alter table public.profiles enable row level security;
alter table public.facilities enable row level security;
alter table public.memberships enable row level security;
alter table public.locks enable row level security;
alter table public.assignments enable row level security;
alter table public.activity enable row level security;
alter table private.approved_users enable row level security;
alter table private.lock_secrets enable row level security;
alter table private.encryption_key enable row level security;
create policy profile_read on public.profiles for select to authenticated using(private.live() and (id=auth.uid() or private.admin() or exists(select 1 from public.memberships m where m.user_id=profiles.id and private.can_access(m.facility_id))));
create policy facilities_read on public.facilities for select to authenticated using(private.can_access(id));
create policy membership_read on public.memberships for select to authenticated using(private.live() and (user_id=auth.uid() or private.admin()));
create policy locks_read on public.locks for select to authenticated using(private.can_access(facility_id));
create policy assignments_read on public.assignments for select to authenticated using(private.can_access(facility_id));
create policy activity_read on public.activity for select to authenticated using((facility_id is not null and private.can_access(facility_id)) or private.admin());
revoke all on public.profiles,public.facilities,public.memberships,public.locks,public.assignments,public.activity from anon,authenticated;
grant select on public.profiles,public.facilities,public.memberships,public.locks,public.assignments,public.activity to authenticated;
create function private.mutate_lock(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare l public.locks;old_l public.locks;lid uuid;fid uuid;act text:=p->>'action';new_status text;u text;c text;s text;v int;
begin
if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
if act='create' then
fid:=(p->>'facility_id')::uuid;perform private.require_access(fid);
if not exists(select 1 from public.facilities where id=fid and active) then raise exception 'Facility is inactive';end if;
s:=trim(p->>'serial');c:=trim(p->>'combination');
if c is null or length(c)<1 or length(c)>200 then raise exception 'A combination is required (maximum 200 characters)';end if;
insert into public.locks(serial,color,facility_id,notes) values(s,p->>'color',fid,coalesce(p->>'notes','')) returning * into l;
insert into private.lock_secrets values(l.id,extensions.pgp_sym_encrypt(c,(select value from private.encryption_key)));
else
select * into l from public.locks where id=(p->>'id')::uuid for update;
if not found then raise exception 'Lock not found';end if;
perform private.require_access(l.facility_id);old_l:=l;
if l.version<>coalesce((p->>'version')::int,-1) then raise exception 'This lock changed. Reopen it and try again.' using errcode='40001';end if;
if act='assign' then
if l.status<>'available' then raise exception 'Return this lock to inventory before assigning it.';end if;
new_status:=p->>'status';u:=trim(p->>'unit');
if new_status not in ('overlock','vacant','auction') or u is null or length(u)<1 or length(u)>60 then raise exception 'Choose an assignment type and enter a unit number.';end if;
insert into public.assignments(lock_id,facility_id,unit,type,assigned_by) values(l.id,l.facility_id,u,new_status,auth.uid());
update public.locks set status=new_status,unit=u,last_assigned_at=now(),last_assigned_by=auth.uid() where id=l.id;
elsif act='release' then
if l.status not in ('overlock','vacant','auction') then raise exception 'This lock is not assigned.';end if;
update public.assignments set released_at=now(),released_by=auth.uid() where lock_id=l.id and released_at is null;
update public.locks set status='available',unit=null where id=l.id;
elsif act='status' then
new_status:=p->>'status';
if l.status in ('overlock','vacant','auction') then raise exception 'Return the lock to inventory first to preserve its assignment.';end if;
if new_status not in ('available','missing','retired') then raise exception 'Invalid status';end if;
update public.locks set status=new_status,unit=null where id=l.id;
elsif act='edit' then
update public.locks set serial=trim(p->>'serial'),color=p->>'color',notes=coalesce(p->>'notes','') where id=l.id;
c:=nullif(trim(p->>'combination'),'');
if c is not null then
if length(c)>200 then raise exception 'Combination is too long';end if;
update private.lock_secrets set encrypted=extensions.pgp_sym_encrypt(c,(select value from private.encryption_key)) where lock_id=l.id;
insert into public.activity(lock_id,facility_id,actor_id,action) values(l.id,l.facility_id,auth.uid(),'combination_corrected');
end if;
else raise exception 'Unknown operation';end if;
update public.locks set updated_at=clock_timestamp(),version=version+1 where id=l.id returning * into l;
end if;
insert into public.activity(lock_id,facility_id,actor_id,action,before_values,after_values) values(l.id,l.facility_id,auth.uid(),act,case when old_l.id is null then null else to_jsonb(old_l) end,to_jsonb(l));
return l.id;
exception when unique_violation then raise exception 'This serial number already exists at this facility.';
end
$$;
create function private.reveal(lid uuid) returns text language plpgsql security definer set search_path='' as $$
declare f uuid;
begin select facility_id into f from public.locks where id=lid;perform private.require_access(f);
return (select extensions.pgp_sym_decrypt(encrypted,(select value from private.encryption_key)) from private.lock_secrets where lock_id=lid);end
$$;
create function private.admin_action(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare fid uuid;uid uuid;f uuid;em text;oldp public.profiles;
begin if not private.admin() then raise exception 'Administrator access required' using errcode='42501';end if;
if p->>'action'='facility' then
if nullif(p->>'id','') is null then
insert into public.facilities(name,identifier,address) values(trim(p->>'name'),trim(p->>'identifier'),nullif(p->>'address','')) returning id into fid;
else
fid:=(p->>'id')::uuid;
update public.facilities set name=trim(p->>'name'),identifier=trim(p->>'identifier'),address=nullif(p->>'address',''),active=(p->>'active')::boolean,updated_at=now() where id=fid;
end if;
insert into public.activity(facility_id,actor_id,action,after_values) values(fid,auth.uid(),'facility_updated',p-'action');return jsonb_build_object('id',fid);
elsif p->>'action'='user' then
em:=lower(trim(p->>'email'));
if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or nullif(trim(p->>'name'),'') is null then raise exception 'Enter a valid name and email';end if;
if p->>'role' not in ('admin','employee') then raise exception 'Invalid role';end if;
select * into oldp from public.profiles where email=em;uid:=oldp.id;
if uid=auth.uid() and (p->>'role'<>'admin' or not (p->>'active')::boolean) then raise exception 'You cannot deactivate or demote your own administrator account';end if;
for f in select jsonb_array_elements_text(coalesce(p->'facility_ids','[]'))::uuid loop
if not exists(select 1 from public.facilities where id=f) then raise exception 'Facility not found';end if;end loop;
insert into private.approved_users(email,name,role,active,facility_ids) values(em,trim(p->>'name'),p->>'role',(p->>'active')::boolean,array(select jsonb_array_elements_text(coalesce(p->'facility_ids','[]'))::uuid))
on conflict(email) do update set name=excluded.name,role=excluded.role,active=excluded.active,facility_ids=excluded.facility_ids;
if uid is not null then
update public.profiles set name=trim(p->>'name'),role=p->>'role',active=(p->>'active')::boolean where id=uid;
delete from public.memberships where user_id=uid;
insert into public.memberships(user_id,facility_id) select uid,jsonb_array_elements_text(coalesce(p->'facility_ids','[]'))::uuid;
if oldp.role<>(p->>'role') or not (p->>'active')::boolean then delete from auth.sessions where user_id=uid;end if;
end if;
insert into public.activity(actor_id,action,after_values) values(auth.uid(),'account_updated',p-'action');
return jsonb_build_object('email',em,'registered',uid is not null);
end if;raise exception 'Unknown administrator operation';end
$$;
create function private.list_accounts() returns jsonb language plpgsql security definer set search_path='' as $$
begin if not private.admin() then raise exception 'Administrator access required';end if;
return coalesce((select jsonb_agg(jsonb_build_object('email',a.email,'name',a.name,'role',a.role,'active',a.active,'facility_ids',a.facility_ids,'registered',p.id is not null) order by a.name) from private.approved_users a left join public.profiles p on p.email=a.email),'[]');end
$$;
create function private.import_locks(rows jsonb) returns int language plpgsql security definer set search_path='' as $$
declare row jsonb;n int:=0;
begin if jsonb_array_length(rows)>1000 or jsonb_array_length(rows)<1 then raise exception 'Import 1 to 1000 locks at a time';end if;
for row in select * from jsonb_array_elements(rows) loop
if coalesce(row->>'status','available')<>'available' then raise exception 'Imports create available locks only. Assign units after importing.';end if;
perform private.mutate_lock(row||jsonb_build_object('action','create'));n:=n+1;end loop;return n;end
$$;
create function public.mutate_lock(p jsonb) returns uuid language sql security invoker set search_path='' as $$select private.mutate_lock(p)$$;
create function public.reveal_combination(lid uuid) returns text language sql security invoker set search_path='' as $$select private.reveal(lid)$$;
create function public.admin_action(p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.admin_action(p)$$;
create function public.list_accounts() returns jsonb language sql security invoker set search_path='' as $$select private.list_accounts()$$;
create function public.import_locks(rows jsonb) returns int language sql security invoker set search_path='' as $$select private.import_locks(rows)$$;
revoke all on all tables in schema private from public,anon,authenticated;
revoke execute on all functions in schema private from public,anon,authenticated;
grant execute on function private.live(),private.admin(),private.can_access(uuid),private.mutate_lock(jsonb),private.reveal(uuid),private.admin_action(jsonb),private.list_accounts(),private.import_locks(jsonb) to authenticated;
revoke execute on function public.mutate_lock(jsonb),public.reveal_combination(uuid),public.admin_action(jsonb),public.list_accounts(),public.import_locks(jsonb) from public,anon;
grant execute on function public.mutate_lock(jsonb),public.reveal_combination(uuid),public.admin_action(jsonb),public.list_accounts(),public.import_locks(jsonb) to authenticated;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema private revoke execute on functions from public;

create function private.inventory_counts(fid uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
if not private.live() then raise exception 'Sign in required';end if;
if fid is not null then perform private.require_access(fid);end if;
return coalesce((select jsonb_object_agg(status,n) from (select status,count(*) n from public.locks where (fid is null or facility_id=fid) and private.can_access(facility_id) group by status) s),'{}');end
$$;
create function public.inventory_counts(fid uuid default null) returns jsonb language sql security invoker set search_path='' as $$select private.inventory_counts(fid)$$;
create function private.validate_import(rows jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;errs jsonb:='[]';f uuid;i int:=1;
begin if not private.live() then raise exception 'Sign in required';end if;
if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>1000 then raise exception 'Import at most 1,000 rows';end if;
for r in select * from jsonb_array_elements(rows) loop
i:=i+1;f:=(r->>'facility_id')::uuid;perform private.require_access(f);
if exists(select 1 from public.locks where facility_id=f and lower(serial)=lower(trim(r->>'serial'))) then errs:=errs||jsonb_build_array('Row '||i||': serial already exists at this facility');end if;
end loop;return errs;end
$$;
create function public.validate_import(rows jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.validate_import(rows)$$;
create or replace function private.import_locks(rows jsonb) returns int language plpgsql security definer set search_path='' as $$
declare r jsonb;n int:=0;lid uuid;s text;
begin if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>1000 or jsonb_array_length(rows)<1 then raise exception 'Import 1 to 1,000 locks at a time';end if;
for r in select * from jsonb_array_elements(rows) loop
s:=coalesce(r->>'status','available');
if s not in ('available','overlock','vacant','auction','missing','retired') then raise exception 'Invalid status';end if;
lid:=private.mutate_lock(r||jsonb_build_object('action','create'));
if s in ('overlock','vacant','auction') then perform private.mutate_lock(jsonb_build_object('action','assign','id',lid,'version',1,'status',s,'unit',r->>'unit'));
elsif s<>'available' then perform private.mutate_lock(jsonb_build_object('action','status','id',lid,'version',1,'status',s));end if;
n:=n+1;end loop;return n;end
$$;
revoke execute on function public.inventory_counts(uuid),public.validate_import(jsonb) from public,anon;
revoke execute on function private.inventory_counts(uuid),private.validate_import(jsonb) from public,anon;
grant execute on function private.inventory_counts(uuid),public.inventory_counts(uuid),private.validate_import(jsonb),public.validate_import(jsonb) to authenticated;
