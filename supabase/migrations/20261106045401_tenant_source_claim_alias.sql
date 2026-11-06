-- Keep queue aliases distinct from the notification record variable.
do $$declare definition text;begin
 definition:=pg_get_functiondef('automation.tenant_request_worker(text,jsonb)'::regprocedure);
 definition:=replace(definition,'join automation.notification_outbox n on n.id=r.notification_id','join automation.notification_outbox queue_row on queue_row.id=r.notification_id');
 definition:=replace(definition,'and n.state=''pending''','and queue_row.state=''pending''');
 definition:=replace(definition,'from automation.notification_outbox n where n.id=r.notification_id','from automation.notification_outbox queue_row where queue_row.id=r.notification_id');
 execute definition;
end $$;
