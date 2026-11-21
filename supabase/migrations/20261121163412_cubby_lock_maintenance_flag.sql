-- Accept a source capability upgrade from an unavailable maintenance flag to a
-- verified value at the same source version only if the older fingerprint matches.
do $migration$
declare definition text:=pg_get_functiondef('automation.lock_mirror_batch(uuid,jsonb)'::regprocedure);
 declaration text:='direct_label text;direct_type text;';
 guard text:='if marker=s.source_marker and fp is distinct from s.source_fingerprint and (meta_fp is distinct from s.source_metadata_fingerprint or (s.combination_verified and coalesce(combo_valid,false))) then';
begin
 if strpos(definition,declaration)=0 or strpos(definition,guard)=0 then
  raise exception 'Lock maintenance integration point changed';
 end if;
 definition:=replace(definition,declaration,declaration||'maintenance_backfill boolean;legacy_metadata jsonb;');
 definition:=replace(definition,guard,$new$
   if marker=s.source_marker and fp is distinct from s.source_fingerprint then
    legacy_metadata:=jsonb_set(j-'unit'-'unitMatches','{needsMaintenance}','null'::jsonb);
    maintenance_backfill:=coalesce(
     s.needs_maintenance is null and jsonb_typeof(j->'needsMaintenance')='boolean'
     and run.capabilities->>'maintenanceColumn' in ('is_needs_maintenance','needs_maintenance')
     and encode(extensions.hmac((legacy_metadata-'combination'-'combinationAvailable')::text,
       (select value from private.encryption_key),'sha256'),'hex')=s.source_metadata_fingerprint,
     false);
    if (meta_fp is distinct from s.source_metadata_fingerprint and not maintenance_backfill)
      or (s.combination_verified and coalesce(combo_valid,false) and not (
       maintenance_backfill and encode(extensions.hmac(legacy_metadata::text,
        (select value from private.encryption_key),'sha256'),'hex')=s.source_fingerprint)) then
   $new$);
 definition:=replace(definition,$old$why:='source_version_conflict';raise exception 'Review required';end if;$old$,
  $new$why:='source_version_conflict';raise exception 'Review required';
    end if;
   end if;$new$);
 execute definition;
end
$migration$;
