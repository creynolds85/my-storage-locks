create or replace function private.cubby_inventory_import(token text,document text,mode text,batch_offset int default 0,batch_size int default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg private.cubby_import_control;doc jsonb;f jsonb;r jsonb;fid uuid;lid uuid;aid uuid;existing public.locks;st text;u text;org text;issues jsonb:='[]';result jsonb;new_f int:=0;new_l int:=0;matched int:=0;preserved int:=0;checked int:=0;before_new int;before_preserved int;before_matched int;apply boolean:=mode='apply';
begin
if session_user<>'postgres' then raise exception 'Privileged migration connection required' using errcode='42501';end if;
select * into cfg from private.cubby_import_control where id;
if cfg.id is null or cfg.closed_at is not null or cfg.expires_at<now() or encode(extensions.digest(token,'sha256'),'hex')<>cfg.token_hash then raise exception 'Migration authorization denied' using errcode='42501';end if;
if encode(extensions.digest(document,'sha256'),'hex')<>cfg.document_hash then raise exception 'Approved snapshot mismatch';end if;
if mode not in ('dry_run','apply','verify') or batch_offset<0 or batch_size not between 1 and 100 then raise exception 'Invalid migration mode or batch';end if;
perform pg_advisory_xact_lock(hashtext('my_storage_locks_cubby_initial_import'));
doc:=document::jsonb;org:=cfg.source_org_id;
if doc->>'source_org_id'<>org or jsonb_array_length(doc->'facilities')<>23 or jsonb_array_length(doc->'locks')<>1146 then raise exception 'Source scope or count mismatch';end if;
if exists(select 1 from jsonb_array_elements(doc->'facilities') x group by x->>'facility_id' having count(*)>1) or exists(select 1 from jsonb_array_elements(doc->'locks') x group by x->>'door_lock_id' having count(*)>1) or exists(select 1 from jsonb_array_elements(doc->'locks') x group by x->>'facility_id',lower(x->>'serial_code') having count(*)>1) then raise exception 'Duplicate source identities';end if;
for f in select value from jsonb_array_elements(doc->'facilities') loop
 begin
 fid:=null;
 select id into fid from public.facilities where source_org_id=org and source_facility_id=f->>'facility_id';
 if fid is null then select facility_id into fid from automation.facility_links where source_org_id=org and source_facility_id=f->>'facility_id';end if;
 if fid is null and exists(select 1 from public.facilities where lower(identifier)=lower(f->>'facility_id')) then raise exception 'Unmapped existing facility';end if;
 if fid is null then
  new_f:=new_f+1;
  if apply then
   insert into public.facilities(name,identifier,address,source_org_id,source_facility_id,source_created_at,source_updated_at) values(f->>'facility_name',f->>'facility_id',nullif(f->>'address',''),org,f->>'facility_id',(f->>'created_at')::timestamptz,(f->>'updated_at')::timestamptz) returning id into fid;
   insert into automation.facility_links(source_org_id,source_facility_id,facility_id) values(org,f->>'facility_id',fid);
  end if;
 elsif apply then
  if exists(select 1 from public.facilities where id=fid and source_facility_id is not null and (source_facility_id<>f->>'facility_id' or source_org_id<>org)) then raise exception 'Facility source conflict';end if;
  update public.facilities set source_org_id=org,source_facility_id=f->>'facility_id',source_created_at=(f->>'created_at')::timestamptz,source_updated_at=(f->>'updated_at')::timestamptz where id=fid and source_facility_id is null;
 end if;
 exception when others then issues:=issues||jsonb_build_array(jsonb_build_object('kind','facility','sourceId',f->>'facility_id','code','facility_conflict_no_overwrite'));end;
end loop;
for r in select value from jsonb_array_elements(doc->'locks') with ordinality as a(value,n) where n>batch_offset and n<=batch_offset+batch_size loop
 checked:=checked+1;before_new:=new_l;before_preserved:=preserved;before_matched:=matched;
 begin
 if r->>'door_lock_id' is null or r->>'serial_code' is null or r->>'combination' is null or length(r->>'combination') not between 1 and 200 or (r->>'serial_code') !~ '^[A-Za-z0-9]{1,100}$' then raise exception 'Invalid source fields';end if;
 if not exists(select 1 from jsonb_array_elements(doc->'facilities') x where x->>'facility_id'=r->>'facility_id') then raise exception 'Unknown facility';end if;
 st:=case r->>'export_status' when 'Available' then 'available' when 'On vacant unit' then 'vacant' when 'Overlocked' then 'overlock' when 'Locked for auction' then 'auction' when 'Locked' then 'unclassified' when 'Used by tenant' then 'tenant_held' when 'Missing' then 'missing' when 'Damaged' then 'damaged' when 'For maintenance' then 'maintenance' else null end;
 if st is null then raise exception 'Unrecognized source status';end if;
 u:=nullif(r->>'export_unit_label','');
 if (r->>'unit_id' is null)<>(u is null) or coalesce((r->>'unit_mapping_conflict')::boolean,true) then raise exception 'Unverified unit mapping';end if;
 if st in ('available','missing','damaged') and u is not null then raise exception 'Unassigned state has unit';end if;
 if st in ('overlock','vacant','auction','unclassified','tenant_held') and u is null then raise exception 'Assignment unit missing';end if;
 fid:=null;select id into fid from public.facilities where source_org_id=org and source_facility_id=r->>'facility_id';
 if apply and fid is null then raise exception 'Facility not imported';end if;
 select * into existing from public.locks where source_org_id=org and source_lock_id=r->>'door_lock_id';
 if found then
  if existing.serial<>r->>'serial_code' or existing.facility_id is distinct from fid or existing.source_unit_id is distinct from r->>'unit_id' or existing.source_status is distinct from r->>'status' or existing.source_display_status is distinct from r->>'export_status' then raise exception 'Existing source metadata conflict';end if;
  if (select extensions.pgp_sym_decrypt(encrypted,(select value from private.encryption_key)) from private.lock_secrets where lock_id=existing.id) is distinct from r->>'combination' then raise exception 'Existing combination conflict';end if;
  matched:=matched+1;preserved:=preserved+1;
 else
  if fid is not null and exists(select 1 from public.locks where facility_id=fid and lower(serial)=lower(r->>'serial_code')) then raise exception 'Existing serial conflict';end if;
  new_l:=new_l+1;
  if apply then
   insert into public.locks(serial,color,facility_id,status,unit,source_org_id,source_lock_id,source_unit_id,source_status,source_display_status,source_created_at,source_updated_at,source_needs_maintenance,source_custom_location,source_updated_by_label,imported_at,created_at,updated_at)
   values(r->>'serial_code','Unknown',fid,st,u,org,r->>'door_lock_id',r->>'unit_id',r->>'status',r->>'export_status',(r->>'created_at')::timestamptz,(r->>'updated_at')::timestamptz,(r->>'needs_maintenance')::boolean,r->>'custom_location',r->>'source_updated_by_label',now(),coalesce((r->>'created_at')::timestamptz,now()),coalesce((r->>'updated_at')::timestamptz,now())) returning id into lid;
   insert into private.lock_secrets(lock_id,encrypted) values(lid,extensions.pgp_sym_encrypt(r->>'combination',(select value from private.encryption_key)));
   if (select extensions.pgp_sym_decrypt(encrypted,(select value from private.encryption_key)) from private.lock_secrets where lock_id=lid) is distinct from r->>'combination' then raise exception 'Encrypted round trip failed';end if;
   preserved:=preserved+1;
   if u is not null then
    insert into automation.unit_links(source_org_id,source_facility_id,source_unit_id,facility_id,label) values(org,r->>'facility_id',r->>'unit_id',fid,u) on conflict(source_org_id,source_unit_id) do nothing;
    if not exists(select 1 from automation.unit_links where source_org_id=org and source_unit_id=r->>'unit_id' and facility_id=fid and label=u) then raise exception 'Existing unit mapping conflict';end if;
    insert into public.assignments(lock_id,facility_id,unit,type,assigned_by,assigned_at,imported_at,source_display_status) values(lid,fid,u,st,null,null,now(),r->>'export_status') returning id into aid;
    insert into automation.assignment_links(assignment_id,source_org_id,source_unit_id) values(aid,org,r->>'unit_id');
   end if;
   insert into public.activity(lock_id,facility_id,action,after_values) values(lid,fid,'cubby_inventory_imported',jsonb_build_object('sourceLockId',r->>'door_lock_id','sourceStatus',r->>'status','sourceDisplayStatus',r->>'export_status','status',st,'unit',u));
  end if;
 end if;
 exception when others then new_l:=before_new;preserved:=before_preserved;matched:=before_matched;issues:=issues||jsonb_build_array(jsonb_build_object('kind','lock','sourceId',r->>'door_lock_id','code','record_conflict_no_overwrite'));end;
end loop;
result:=jsonb_build_object('mode',mode,'sourceFacilities',23,'sourceLocks',1146,'batchOffset',batch_offset,'checked',checked,'newFacilities',new_f,'newLocks',new_l,'matchedExistingLocks',matched,'combinationRecordsVerified',preserved,'issues',issues,'recordsApplied',case when apply then new_l else 0 end);
insert into private.cubby_import_audit(document_hash,mode,batch_offset,result) values(cfg.document_hash,mode,batch_offset,result);
return result;
end $$;

revoke execute on function private.cubby_inventory_import(text,text,text,int,int),public.cubby_inventory_import(text,text,text,int,int) from public,anon,authenticated;
