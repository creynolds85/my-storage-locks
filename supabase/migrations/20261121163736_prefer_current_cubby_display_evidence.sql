-- Exact current labels outrank the original import, even when a field capability
-- upgrade replays an otherwise identical source lock version.
do $migration$
declare definition text:=pg_get_functiondef('automation.lock_mirror_batch(uuid,jsonb)'::regprocedure);
 stripped text:='j:=j-''physicalColor''-''sourceDisplayStatus'';';
 fast_path text:='and direct_label is null then';
 label_branch text:='if direct_label is not null and j->>''status''=''ACTIVE'' then';
 binding text:='if direct_type is not null and direct_type=typ and binding_same';
begin
 if strpos(definition,stripped)=0 or strpos(definition,fast_path)=0 or strpos(definition,label_branch)=0 or strpos(definition,binding)=0 then
  raise exception 'Current Cubby display evidence integration point changed';
 end if;
 definition:=replace(definition,'direct_type text;', 'direct_type text;effective_label text;effective_type text;');
 definition:=replace(definition,stripped,stripped||$new$
   effective_label:=direct_label;
   if effective_label is null and j->>'status'='ACTIVE' then
    select e.display_status into effective_label from automation.lock_mirror_display_evidence e
    where e.source_org_id=run.source_org_id and e.source_lock_id=j->>'sourceLockId'
     and e.source_facility_id=j->>'facilityId' and e.source_marker=marker
     and e.source_unit_id is not distinct from j->>'unitId';
   end if;
   effective_type:=automation.cubby_lock_display_type(effective_label,j->>'status',(j->>'needsMaintenance')::boolean);
 $new$);
 definition:=replace(definition,fast_path,$new$and direct_label is null
    and (effective_label is null or
     (effective_type is null and not s.purpose_verified) or
     (effective_type=l.status and s.purpose_verified)) then$new$);
 definition:=replace(definition,label_branch,'if effective_label is not null and j->>''status''=''ACTIVE'' then');
 definition:=replace(definition,'purpose:=direct_type is not null;','purpose:=effective_type is not null;');
 definition:=replace(definition,'typ:=coalesce(direct_type,','typ:=coalesce(effective_type,');
 definition:=replace(definition,binding,'if effective_type is not null and effective_type=typ and binding_same');
 execute definition;
end
$migration$;
