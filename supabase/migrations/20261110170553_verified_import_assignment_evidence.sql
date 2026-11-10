-- Preserve assigned_at=NULL and original source fields. An imported assignment
-- can predate an event only when the same verified source lock/unit/purpose
-- was recorded and linked beforehand. No inventory or activation writes.
do $$
declare definition text;needle text;binding text;replacement text;begin
 binding:=$predicate$(a.assigned_at is null and a.imported_at is not null
  and a.source_display_status=case a.type when 'vacant' then 'On vacant unit' when 'overlock' then 'Overlocked' end
  and l.source_display_status=a.source_display_status and l.source_status='ACTIVE'
  and l.source_org_id=s.source_org_id and l.source_unit_id=s.source_unit_id
  and nullif(l.source_lock_id,'') is not null)$predicate$;
 definition:=pg_get_functiondef('automation.worker(text,text,jsonb)'::regprocedure);
 needle:='''assignedAt'',a.assigned_at)';
 if position(needle in definition)=0 then raise exception 'Assignment context integration point changed';end if;
 replacement:='''assignedAt'',a.assigned_at,''importedAt'',a.imported_at,''mappingVerifiedAt'',al.linked_at,''importedMappingVerified'','||binding||')';
 execute replace(definition,needle,replacement);
 definition:=pg_get_functiondef('automation.is_current(automation.notification_outbox)'::regprocedure);
 needle:='a.assigned_at<=n.source_occurred_at';
 if position(needle in definition)=0 then raise exception 'Assignment dispatch integration point changed';end if;
 replacement:='(a.assigned_at<=n.source_occurred_at or ('||binding||' and a.imported_at<=n.source_occurred_at and al.linked_at<=n.source_occurred_at))';
 execute replace(definition,needle,replacement);
end $$;
