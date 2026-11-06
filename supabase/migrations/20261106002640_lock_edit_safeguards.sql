create or replace function private.mutate_lock(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare l public.locks;old_l public.locks;lid uuid;fid uuid;act text:=p->>'action';new_status text;u text;c text;s text;v int;notice automation.notification_outbox;
begin
if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
if act='create' then
fid:=(p->>'facility_id')::uuid;perform private.require_access(fid);
if not exists(select 1 from public.facilities where id=fid and active) then raise exception 'Facility is inactive';end if;
s:=trim(p->>'serial');c:=p->>'combination';
if c is null or length(c)<1 or length(c)>200 then raise exception 'A combination is required (maximum 200 characters)';end if;
insert into public.locks(serial,color,facility_id,notes) values(s,p->>'color',fid,coalesce(p->>'notes','')) returning * into l;
insert into private.lock_secrets values(l.id,extensions.pgp_sym_encrypt(c,(select value from private.encryption_key)));
else
select * into l from public.locks where id=(p->>'id')::uuid for update;
if not found then raise exception 'Lock not found';end if;
perform private.require_access(l.facility_id);old_l:=l;
if p ? 'serial' and p->>'serial' is distinct from l.serial then raise exception 'Serial numbers cannot be changed here.' using errcode='22023';end if;
if l.version<>coalesce((p->>'version')::int,-1) then raise exception 'This lock changed. Reopen it and try again.' using errcode='40001';end if;
if act='assign' then
if l.status<>'available' then raise exception 'Return this lock to inventory before assigning it.';end if;
new_status:=p->>'status';u:=trim(p->>'unit');
if new_status not in ('overlock','vacant','auction') or u is null or length(u)<1 or length(u)>60 then raise exception 'Choose an assignment type and enter a unit number.';end if;
insert into public.assignments(lock_id,facility_id,unit,type,assigned_by) values(l.id,l.facility_id,u,new_status,auth.uid());
update public.locks set status=new_status,unit=u,last_assigned_at=now(),last_assigned_by=auth.uid() where id=l.id;
elsif act='release' then
if not exists(select 1 from public.assignments where lock_id=l.id and released_at is null) then raise exception 'This lock is not assigned.';end if;
update public.assignments set released_at=now(),released_by=auth.uid() where lock_id=l.id and released_at is null;
update public.locks set status='available',unit=null where id=l.id;
elsif act='status' then
new_status:=p->>'status';
if exists(select 1 from public.assignments where lock_id=l.id and released_at is null) then raise exception 'Confirm physical recovery before changing its status.';end if;
if new_status not in ('available','missing','retired','damaged','maintenance') then raise exception 'Invalid status';end if;
update public.locks set status=new_status,unit=null where id=l.id;
elsif act='classify' then
new_status:=p->>'status';
if l.status<>'unclassified' or new_status not in ('overlock','vacant','auction') or l.unit is null then raise exception 'Choose a verified purpose for an unclassified assigned lock';end if;
if not exists(select 1 from public.assignments where lock_id=l.id and released_at is null) then raise exception 'Current assignment missing';end if;
update public.assignments set type=new_status where lock_id=l.id and released_at is null;
update public.locks set status=new_status where id=l.id;
elsif act='edit' then
if p ? 'combination' or p ? 'confirm_combination' then raise exception 'Use Change Combination to update a combination.' using errcode='22023';end if;
if length(coalesce(p->>'notes',''))>4000 then raise exception 'Notes are too long.' using errcode='22023';end if;
update public.locks set color=p->>'color',notes=coalesce(p->>'notes','') where id=l.id;
elsif act='change_combination' then
c:=p->>'combination';
if c is null or length(c) not between 1 and 200 or p->>'confirm_combination' is distinct from c or p->'physical_verified' is distinct from 'true'::jsonb then
 raise exception 'Confirm the new combination and verify the physical lock.' using errcode='22023';end if;
-- The claim path locks an outbox row before locking the lock. NOWAIT prevents
-- waiting in the reverse order, and prevents a save while a dispatch is reserved.
-- Only rows locked by this loop are changed; newly enqueued rows still have to
-- pass the existing final lock-version guard before obtaining a combination.
for notice in select * from automation.notification_outbox where lock_id=l.id and state in ('pending','dry_run','dispatching','unknown') order by id for update nowait loop
 if notice.state in ('dispatching','unknown') then
  raise exception 'An access message needs confirmation before this combination can change.' using errcode='55P03';
 end if;
 update automation.notification_outbox set state='cancelled',error_code='combination_changed' where id=notice.id;
 insert into automation.notification_attempts(notification_id,event_key,state,error_code)
 values(notice.id,'combination-change:'||notice.id::text||':'||l.version::text,'cancelled','combination_changed');
 update public.action_items set notification_state='cancelled',updated_at=now() where notification_id=notice.id;
 perform automation.task('combination-change:'||notice.id::text,l.facility_id,'assignment_conflict','Tenant access needs review','The lock combination changed. Review tenant access before sending another message.',notice.assignment_id,notice.id,'unverified','cancelled');
end loop;
update private.lock_secrets set encrypted=extensions.pgp_sym_encrypt(c,(select value from private.encryption_key)) where lock_id=l.id;
if not found then raise exception 'Unable to update this combination.';end if;
else raise exception 'Unknown operation';end if;
update public.locks set updated_at=clock_timestamp(),version=version+1 where id=l.id returning * into l;
end if;
insert into public.activity(lock_id,facility_id,actor_id,action,before_values,after_values) values(l.id,l.facility_id,auth.uid(),act,case when old_l.id is null then null else to_jsonb(old_l) end,to_jsonb(l));
return l.id;
exception when unique_violation then raise exception 'This serial number already exists at this facility.';
end
$$;


-- Backend audit data stays in its existing tables, with no browser read grant.
revoke select on public.activity,public.assignments from authenticated;
-- Deny source provenance and historical actor metadata through direct Data API reads.
revoke select on public.locks,public.facilities from authenticated;
grant select(id,serial,color,facility_id,status,unit,notes,version,created_at,updated_at) on public.locks to authenticated;
grant select(id,name,identifier,address,active) on public.facilities to authenticated;

create function private.has_current_assignment(lid uuid) returns boolean language plpgsql stable security definer set search_path='' as $$
declare f uuid;begin
 select facility_id into f from public.locks where id=lid;
 perform private.require_access(f);
 return exists(select 1 from public.assignments where lock_id=lid and released_at is null);
end $$;
create function public.has_current_assignment(lid uuid) returns boolean language sql stable security invoker set search_path='' as $$select private.has_current_assignment(lid)$$;
revoke execute on function private.has_current_assignment(uuid),public.has_current_assignment(uuid) from public,anon;
grant execute on function private.has_current_assignment(uuid),public.has_current_assignment(uuid) to authenticated;

-- Only operational action items are returned. Configuration, synchronization
-- metadata, provider identifiers and raw technical details stay on the backend.
create or replace function automation.dashboard(fid uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
 if fid is not null then perform private.require_access(fid);end if;
 return jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(t)) from (
  select id,kind,
   case kind when 'overlock_removal' then 'Overlock removal required' when 'vacant_recovery' then 'Vacant lock recovery required' when 'missing_assignment' then 'Physical lock assignment needed' when 'sms_failure' then 'Tenant notification needs attention' when 'sync_failure' then 'Automatic access messages need attention' else 'Lock assignment needs review' end as title,
   case kind when 'overlock_removal' then 'Confirm the physical lock has been recovered before returning it to inventory.' when 'vacant_recovery' then 'Recover the lock from the rented unit and confirm its return.' when 'missing_assignment' then 'Check the unit and confirm the correct physical lock assignment.' when 'sms_failure' then 'Confirm whether the tenant received access instructions before sending another message.' when 'sync_failure' then 'Contact an administrator. Physical lock management remains available.' else 'Check the current lock assignment and tenant access before sending a combination.' end as detail,
   eligibility_state,notification_state,recovered_at is not null as recovered
  from public.action_items where state='open' and (private.admin() or (facility_id is not null and private.can_access(facility_id))) and (fid is null or facility_id=fid)
  order by created_at desc limit 100
 ) t),'[]'::jsonb));
end $$;
-- Direct action-item reads are restricted to fields needed for operational tasks.
revoke select on public.action_items from authenticated;
grant select(id,facility_id,kind,title,state,eligibility_state,notification_state) on public.action_items to authenticated;

create or replace function public.inventory_listing(p_query text default '',p_facility uuid default null,p_statuses text[] default null,p_sort text default 'serial',p_limit int default 100,p_offset int default 0,p_exact_count boolean default true) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare needle text:=lower(regexp_replace(coalesce(p_query,''),'[^a-zA-Z0-9]','','g'));result jsonb;facility_row record;chunk jsonb;items jsonb:='[]';needed int;
begin
 if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
 if p_facility is not null and not private.can_access(p_facility) then raise exception 'Facility access denied' using errcode='42501';end if;
 if p_sort not in ('serial','facility_serial','updated_at','created_at') or p_limit not between 1 and 500 or p_offset<0 then raise exception 'Invalid inventory query';end if;
 -- Dashboard results need a bounded list, not an exact count of every match.
 if not p_exact_count and p_offset=0 and (p_sort='facility_serial' or (p_sort='serial' and p_facility is not null)) then
  for facility_row in select id,name from public.facilities where p_facility is null or id=p_facility order by name collate public.inventory_natural,id loop
   needed:=p_limit+1-jsonb_array_length(items);
   select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) into chunk from (
    select l.id,l.serial,l.color,l.facility_id,l.status,l.unit,l.notes,l.version,facility_row.name as facility_name from public.locks l
    where l.facility_id=facility_row.id and (p_statuses is null or l.status=any(p_statuses))
     and (coalesce(p_query,'')='' or (needle<>'' and lower(l.serial) like '%'||needle||'%'))
    order by
     case when l.serial ~ '^[0-9]+$' then 0 when l.serial ~ '^[0-9]' then 1 else 2 end,
     (case when l.serial ~ '^[0-9]' and l.serial !~ '^[0-9]+$' then substring(l.serial from '^[0-9]+') else '' end) collate "C",
     l.serial collate public.inventory_natural,lower(l.serial) collate "C",l.serial collate "C",l.id
    limit needed
   ) q;
   items:=items||chunk;exit when jsonb_array_length(items)>p_limit;
  end loop;
  return jsonb_build_object('items',coalesce((select jsonb_agg(value) from (select value from jsonb_array_elements(items) with ordinality x(value,n) where n<=p_limit order by n) shown),'[]'::jsonb),'total',null,'hasMore',jsonb_array_length(items)>p_limit);
 end if;
 with visible_facilities as materialized (select id,name from public.facilities where p_facility is null or id=p_facility), filtered as materialized (
  select l.id,l.serial,l.color,l.facility_id,l.status,l.unit,l.notes,l.version,l.created_at,l.updated_at,f.name as facility_name,
   case when l.serial ~ '^[0-9]+$' then 0 when l.serial ~ '^[0-9]' then 1 else 2 end as serial_kind,
   case when l.serial ~ '^[0-9]' and l.serial !~ '^[0-9]+$' then substring(l.serial from '^[0-9]+') else '' end as serial_prefix
  from public.locks l join visible_facilities f on f.id=l.facility_id
  where (p_facility is null or l.facility_id=p_facility)
   and (p_statuses is null or l.status=any(p_statuses))
   and (coalesce(p_query,'')='' or (needle<>'' and lower(l.serial) like '%'||needle||'%'))
 ), page as (
  select * from filtered order by
   case when p_sort='facility_serial' then facility_name end collate public.inventory_natural,
   case when p_sort='updated_at' then updated_at end desc nulls last,
   case when p_sort='created_at' then created_at end desc nulls last,
   serial_kind,serial_prefix collate "C",serial collate public.inventory_natural,lower(serial) collate "C",serial collate "C",facility_id,id
  limit (p_limit+case when p_exact_count then 0 else 1 end) offset p_offset
 )
 select jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(shown)-'serial_kind'-'serial_prefix'-'created_at'-'updated_at') from (select * from page limit p_limit) shown),'[]'::jsonb),'total',case when p_exact_count then (select count(*) from filtered) else null end,'hasMore',(select count(*) from page)>p_limit) into result;
 return result;
end $$;
