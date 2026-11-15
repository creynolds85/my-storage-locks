-- Reuse the existing worker API schema; do not widen anonymous access to private.
alter function private.walkthrough_source_save(text,uuid,jsonb) set schema automation;
create or replace function public.walkthrough_source_save(token text,fid uuid,p jsonb) returns jsonb language sql security invoker set search_path='' as $$select automation.walkthrough_source_save(token,fid,p)$$;
revoke all on function automation.walkthrough_source_save(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function automation.walkthrough_source_save(text,uuid,jsonb) to anon;
