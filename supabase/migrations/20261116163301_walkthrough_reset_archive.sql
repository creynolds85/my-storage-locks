-- Backend-only retention for explicitly authorized inspection deletion/reset operations.
create table private.walkthrough_reset_archive(
 id uuid primary key default gen_random_uuid(),original_week_id uuid not null,
 facility_id uuid not null references public.facilities,
 archived_at timestamptz not null default now(),reason text not null,snapshot jsonb not null
);
alter table private.walkthrough_reset_archive enable row level security;
revoke all on private.walkthrough_reset_archive from public,anon,authenticated;
