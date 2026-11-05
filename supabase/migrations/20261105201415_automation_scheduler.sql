-- A database scheduler operates independently of employee sessions or Vercel cron plan limits.
create extension if not exists pg_cron;
create extension if not exists pg_net;
create function automation.scheduled_tick() returns void language plpgsql security definer set search_path='' as $$
declare credential text;n automation.notification_outbox;cfg automation.settings;begin
 select * into cfg from automation.settings where id;
 if cfg.last_tick_at is null or cfg.last_tick_at<now()-interval '3 minutes' then
 perform automation.task('sync:worker',null,'sync_failure','Background synchronization needs attention','The unattended worker has not reported a recent heartbeat.');
 else update public.action_items set state='resolved',resolved_at=now(),updated_at=now() where cause_key='sync:worker' and state='open';end if;
 if cfg.last_sync_at is not null and cfg.last_sync_at<now()-interval '3 minutes' then
 perform automation.task('sync:stale',null,'sync_failure','Cubby operational data is stale','The last successful synchronization is more than three minutes old. Fresh verification is required before any disclosure.');
 else update public.action_items set state='resolved',resolved_at=now(),updated_at=now() where cause_key='sync:stale' and state='open';end if;
 for n in update automation.notification_outbox set state='unknown',error_code='dispatch_outcome_unknown' where state='dispatching' and dispatch_started_at<now()-interval '120 seconds' returning * loop
 perform automation.task('sms:'||n.id::text,n.facility_id,'sms_failure','SMS outcome needs reconciliation','The provider may have accepted this message. Automatic resend is blocked.',n.assignment_id,n.id,'confirmed','unknown');end loop;
 select decrypted_secret into credential from vault.decrypted_secrets where name='my_storage_locks_cron_secret';
 if nullif(credential,'') is null then return;end if;
 perform net.http_post(url:='https://mystoragelocks.com/api/automation/tick',headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||credential),body:='{}'::jsonb,timeout_milliseconds:=120000);
end $$;
revoke all on function automation.scheduled_tick() from public,anon,authenticated;
-- Credentials are provisioned after the endpoint deploys. Until then this only runs the watchdog.
select cron.schedule('my-storage-locks-minute','* * * * *','select automation.scheduled_tick()');
