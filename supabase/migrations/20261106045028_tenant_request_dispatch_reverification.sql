-- A queued request reuses its reserved verification slot for the mandatory
-- fresh pre-dispatch check. Public intake cannot select this operation.
do $$declare definition text;old_budget text;new_budget text;old_claim text;new_claim text;begin
 definition:=pg_get_functiondef('automation.tenant_request_worker(text,jsonb)'::regprocedure);
 old_budget:=$old$if (select count(*) from automation.tenant_requests where last_attempt_at>now()-interval '1 minute')>=6 then return 'false'::jsonb;end if;$old$;
 new_budget:=$new$if (select count(*) from automation.tenant_requests where last_attempt_at>now()-interval '1 minute')>=6 and not ((p->>'revalidate')::boolean is true and exists(select 1 from automation.tenant_requests r join automation.notification_outbox n on n.id=r.notification_id where r.id=(p->>'id')::uuid and r.last_attempt_at>now()-interval '1 minute' and r.state='pending_delivery' and r.verified_at>now()-interval '120 seconds' and n.state='pending')) then return 'false'::jsonb;end if;$new$;
 old_claim:=$old$update automation.tenant_requests set last_attempt_at=now(),verification_attempts=verification_attempts+1 where id=(p->>'id')::uuid and state in ('pending','verified','dry_run','pending_delivery') and expires_at>now() and (last_attempt_at is null or last_attempt_at<now()-interval '3 seconds');$old$;
 new_claim:=$new$update automation.tenant_requests r set last_attempt_at=now(),verification_attempts=r.verification_attempts+1 where r.id=(p->>'id')::uuid and r.state in ('pending','verified','dry_run','pending_delivery') and r.expires_at>now() and (r.last_attempt_at is null or r.last_attempt_at<now()-interval '3 seconds' or ((p->>'revalidate')::boolean is true and r.state='pending_delivery' and r.verified_at>now()-interval '120 seconds' and exists(select 1 from automation.notification_outbox n where n.id=r.notification_id and n.state='pending')));$new$;
 if position(old_budget in definition)=0 or position(old_claim in definition)=0 then raise exception 'Tenant verification integration point changed';end if;
 execute replace(replace(definition,old_budget,new_budget),old_claim,new_claim);
end $$;
