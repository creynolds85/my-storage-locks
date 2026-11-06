-- Public abuse cannot multiply external verification traffic without a durable cap.
alter table automation.tenant_requests add column last_attempt_at timestamptz,add column verification_attempts int not null default 0;
create index tenant_request_created_time on automation.tenant_requests(created_at desc);
create index tenant_request_source_attempt on automation.tenant_requests(last_attempt_at desc) where last_attempt_at is not null;
do $$declare definition text;needle text:='elsif operation=''tenant_get'' then';replacement text;begin
 definition:=pg_get_functiondef('automation.tenant_request_worker(text,jsonb)'::regprocedure);
 replacement:=$branch$elsif operation='tenant_source_claim' then
  perform pg_advisory_xact_lock(hashtextextended('tenant-source-budget',0));
  if (select count(*) from automation.tenant_requests where last_attempt_at>now()-interval '1 minute')>=6 then return 'false'::jsonb;end if;
  update automation.tenant_requests set last_attempt_at=now(),verification_attempts=verification_attempts+1 where id=(p->>'id')::uuid and state in ('pending','verified','dry_run','pending_delivery') and expires_at>now() and (last_attempt_at is null or last_attempt_at<now()-interval '3 seconds');
  return to_jsonb(found);
elsif operation='tenant_get' then$branch$;
 if position(needle in definition)=0 then raise exception 'Tenant source integration point changed';end if;
 execute replace(definition,needle,replacement);
end $$;
