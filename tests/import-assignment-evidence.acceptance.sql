-- Execute inside BEGIN/ROLLBACK only. Fixtures preserve unknown assignment dates.
do $$
declare f uuid:=gen_random_uuid();l uuid:=gen_random_uuid();a uuid:=gen_random_uuid();actor uuid:=gen_random_uuid();cid uuid;
 org text:='assignment-proof-fixture-'||gen_random_uuid();fac text:='fac-'||gen_random_uuid();u text:='unit-'||gen_random_uuid();
 lease text:='lease-'||gen_random_uuid();customer text:='customer-'||gen_random_uuid();
 ph text:=encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');n automation.notification_outbox;begin
 insert into auth.users(id,email) values(actor,actor::text||'@example.invalid');
 insert into public.profiles(id,email,name,role) values(actor,actor::text||'@example.invalid','Disposable Assignment Proof Fixture','employee');
 insert into public.facilities(id,name,identifier,source_org_id,source_facility_id) values(f,'Disposable Assignment Proof Fixture',f::text,org,fac);
 insert into automation.facility_links values(org,fac,f,'the controlled fixture return box');
 insert into public.locks(id,serial,color,facility_id,status,unit,source_org_id,source_lock_id,source_unit_id,source_status,source_display_status,imported_at)
 values(l,'IMPORTQA'||replace(l::text,'-',''),'Green',f,'vacant','QA001',org,'source-lock-fixture',u,'ACTIVE','On vacant unit',now()-interval '1 hour');
 insert into public.assignments(id,lock_id,facility_id,unit,type,assigned_by,assigned_at,imported_at,source_display_status)
 values(a,l,f,'QA001','vacant',null,null,now()-interval '1 hour','On vacant unit');
 insert into automation.assignment_links values(a,org,u,now()-interval '1 hour');
 insert into automation.operational_snapshots(lease_id,source_org_id,source_facility_id,source_unit_id,customer_id,facts,phone_hash,suppressed,unit_label)
 values(lease,org,fac,u,customer,jsonb_build_object('verified',true,'verifiedAt',now(),'occurredAt',now()-interval '30 seconds','active',true,'paymentClear',true,'auctionClear',true,'restrictionsClear',true,'overlockNeeded',false,'rentalCompleted',true,'episodeId','import-proof-fixture','requirementsSatisfied',true,'moveInAllowed',true),ph,false,'QA001');
 insert into automation.sms_consents(facility_id,customer_id,phone_hash,purpose,proof_source,proof_version,granted_at,recorded_by)
 values(f,customer,ph,'lock_access','controlled acceptance fixture','fixture',now(),actor) returning id into cid;
 n.facility_id:=f;n.assignment_id:=a;n.lock_id:=l;n.lock_version:=1;n.lease_id:=lease;n.customer_id:=customer;n.source_unit_id:=u;n.phone_hash:=ph;n.consent_id:=cid;
 n.kind:='new_rental';n.initiator:='automatic';n.episode_id:='import-proof-fixture';n.source_occurred_at:=now()-interval '30 seconds';
 if not automation.is_current(n) then raise exception 'FAIL verified import binding';end if;
 update public.assignments set imported_at=now() where id=a;
 if automation.is_current(n) then raise exception 'FAIL import after event';end if;
 update public.assignments set imported_at=now()-interval '1 hour' where id=a;
 update automation.assignment_links set linked_at=now() where assignment_id=a;
 if automation.is_current(n) then raise exception 'FAIL mapping after event';end if;
 update automation.assignment_links set linked_at=now()-interval '1 hour' where assignment_id=a;
 update public.locks set source_unit_id='different-unit-fixture' where id=l;
 if automation.is_current(n) then raise exception 'FAIL changed original source unit';end if;
 update public.locks set source_unit_id=u where id=l;
 update public.assignments set source_display_status='Unclassified' where id=a;
 if automation.is_current(n) then raise exception 'FAIL unverified imported purpose';end if;
 update public.assignments set source_display_status='On vacant unit',assigned_at=now() where id=a;
 if automation.is_current(n) then raise exception 'FAIL known later assignment hidden by import';end if;
 update public.assignments set assigned_at=null where id=a;
 update automation.sms_consents set revoked_at=now() where id=cid;
 if automation.is_current(n) then raise exception 'FAIL revoked consent';end if;
 update automation.sms_consents set revoked_at=null where id=cid;
 if not automation.is_current(n) then raise exception 'FAIL restored current fixture';end if;
 if (select assigned_at from public.assignments where id=a) is not null then raise exception 'FAIL fabricated assignment date';end if;
 if (select mode from automation.settings where id)<>'dry_run' then raise exception 'FAIL live mode changed';end if;
end $$;
select 'PASS: verified import provenance, mapping time, immutable unit/purpose, known later assignment and consent checks; dates and production inventory unchanged' result;
