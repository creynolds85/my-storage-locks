-- The approved snapshot has been imported and independently verified. Retain only its redacted audit.
update private.cubby_import_control set closed_at=now() where id and closed_at is null;
revoke execute on function private.cubby_inventory_import(text,text,text,int,int),public.cubby_inventory_import(text,text,text,int,int) from public,anon,authenticated;
-- This empty, unused transport experiment never contained keys or inventory.
drop table if exists private.cubby_import_envelope;
drop extension if exists pgsodium;
