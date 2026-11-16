begin;
-- Isolated fixture: no real lock, unit, combination or inspection is changed.
insert into public.facilities(id,name,identifier) values('96000000-0000-0000-0000-000000000001','Assignment QA','ASSIGNMENT-QA');
insert into private.walkthrough_sources values('96000000-0000-0000-0000-000000000001','[{"unitId":"old_source","label":"0010","kind":"vacant"},{"unitId":"new_source","label":"0020","kind":"vacant"}]','cubby',now());
insert into private.walkthrough_policies(facility_id,vacant_required) values('96000000-0000-0000-0000-000000000001',true);
insert into public.locks(id,serial,color,facility_id,status,unit,source_unit_id) values('96000000-0000-0000-0000-000000000002','QA00001','Unknown','96000000-0000-0000-0000-000000000001','vacant','0020','old_source');
insert into public.assignments(lock_id,facility_id,unit,type,assigned_at) values('96000000-0000-0000-0000-000000000002','96000000-0000-0000-0000-000000000001','0020','vacant',null);
do $$declare f uuid:='96000000-0000-0000-0000-000000000001';e jsonb;begin
 e:=private.walkthrough_expected(f,'{"unitId":"new_source","label":"0020","kind":"vacant"}');
 if (e->>'missing')::boolean or jsonb_array_length(e->'locks')<>1 then raise exception 'FAIL current assignment ignored';end if;
 e:=private.walkthrough_expected(f,'{"unitId":"old_source","label":"0010","kind":"vacant"}');
 if not (e->>'missing')::boolean or jsonb_array_length(e->'locks')<>0 then raise exception 'FAIL original source pointer treated as current';end if;
 perform private.walkthrough_missing(f);perform private.walkthrough_missing(f);
 if (select count(*) from public.action_items where facility_id=f and state='open')<>1 then raise exception 'FAIL missing task deduplication';end if;
 -- Existing unclassified assignment is not a missing physical assignment.
 update public.locks set status='unclassified',unit='0010' where id='96000000-0000-0000-0000-000000000002';
 update public.assignments set type='unclassified',unit='0010' where lock_id='96000000-0000-0000-0000-000000000002';
 e:=private.walkthrough_expected(f,'{"unitId":"old_source","label":"0010","kind":"vacant"}');
 if (e->>'missing')::boolean or not (e->>'assignmentReview')::boolean then raise exception 'FAIL unknown purpose misreported as missing';end if;
 perform private.walkthrough_missing(f);
 if not exists(select 1 from public.action_items where facility_id=f and unit_label='0010' and title='Verify assigned lock purpose' and lock_type is null and state='open') then raise exception 'FAIL review still offers add-lock';end if;
 -- Verify the purpose, then only its affected missing/review task resolves.
 update public.locks set status='vacant' where id='96000000-0000-0000-0000-000000000002';
 update public.assignments set type='vacant' where lock_id='96000000-0000-0000-0000-000000000002';
 perform private.walkthrough_missing(f);
 if exists(select 1 from public.action_items where facility_id=f and unit_label='0010' and state='open') then raise exception 'FAIL verified assignment task not resolved';end if;
 -- Inconsistent current records and duplicate labels must request review.
 update public.assignments set unit='0020' where lock_id='96000000-0000-0000-0000-000000000002';
 e:=private.walkthrough_expected(f,'{"unitId":"new_source","label":"0020","kind":"vacant"}');
 if not (e->>'assignmentReview')::boolean then raise exception 'FAIL inconsistent binding accepted';end if;
 if has_table_privilege('authenticated','private.lock_assignment_reconciliations','select') or has_table_privilege('anon','private.lock_assignment_reconciliations','select') then raise exception 'FAIL private evidence exposed';end if;
end $$;
rollback;
select 'PASS: current binding, immutable provenance, review vs missing, deduplication, selective resolution and private audit; fixtures rolled back' as result;
