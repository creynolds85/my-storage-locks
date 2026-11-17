-- Mirror authority and manager task activation are separate, backend-only decisions.
-- Switching authority alone must not enable alerts or replay historical items.
alter table automation.lock_mirror_control add column action_items_enabled boolean not null default false;
create function automation.manager_actions_enabled() returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select mode='msl_authoritative' and action_items_enabled from automation.lock_mirror_control where id),false)
$$;
revoke all on function automation.manager_actions_enabled() from public,anon,authenticated;
grant execute on function automation.manager_actions_enabled() to authenticated;

-- Cover automation.task(), direct Walk-Through inserts, conflict upserts, and reopen attempts.
-- Do not change notification queues, inspections, mirror records, or historical item data.
create function automation.guard_manager_action_generation() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not automation.manager_actions_enabled() and (TG_OP='INSERT' or (new.state='open' and old.state is distinct from 'open')) then
  -- Existing restricted database logs retain a minimal diagnostic without notes or codes.
  raise log 'msl_manager_action_suppressed kind=%',new.kind;
  return null;
 end if;
 return new;
end $$;
revoke all on function automation.guard_manager_action_generation() from public,anon,authenticated;
create trigger manager_action_generation_gate before insert or update on public.action_items
 for each row execute function automation.guard_manager_action_generation();

-- Stale browser builds also receive no tasks and cannot resolve/recover through this feature.
-- Backend administration retains access to historical rows.
alter policy action_read on public.action_items using(
 automation.manager_actions_enabled() and private.live() and
 (private.admin() or (facility_id is not null and private.can_access(facility_id)))
);
create or replace function public.automation_dashboard(fid uuid default null) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
 if fid is not null and not private.can_access(fid) then raise exception 'Facility access denied' using errcode='42501';end if;
 if not automation.manager_actions_enabled() then return jsonb_build_object('items','[]'::jsonb);end if;
 return automation.dashboard(fid);
end $$;
create or replace function public.automation_action(p jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 if not private.live() then raise exception 'Sign in required' using errcode='42501';end if;
 if not automation.manager_actions_enabled() then raise exception 'Action Items are disabled' using errcode='42501';end if;
 return automation.action(p);
end $$;
