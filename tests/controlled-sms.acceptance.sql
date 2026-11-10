-- Isolated database only. Exact disposable payload supplied out of source.
do $$
declare payload jsonb:=current_setting('controlled.fixture_payload')::jsonb;r jsonb;attempt uuid;denied boolean;begin
 insert into automation.controlled_sms_test(id,phone_hash,body_hash,encrypted_payload,recipient_authorized_at,authorization_source)
 values('294f24bd-2e55-46d8-bcd6-354faa418d5b','daecc6a756afc5e3afb72983a2f23862de66afc377bf959f162e651edb0c2694','01e6ae8cc7462d7ab47cf006d9e8e9c630ec7ed1c55f43fb9c6cd8472e4586b8',extensions.pgp_sym_encrypt(payload::text,(select value from private.encryption_key)),now(),'Isolated recipient-scope fixture');
 if automation.controlled_sms_worker('controlled_sms_claim','{}') is not null then raise exception 'FAIL missing send approval';end if;
 r:=automation.controlled_sms_worker('controlled_sms_inspect','{}');
 if r ? 'body' or r ? 'phone' or r->>'approved'<>'false' then raise exception 'FAIL preparation response';end if;
 update automation.controlled_sms_test set send_approved_at=now()-interval '1 second',approval_expires_at=now()+interval '5 minutes';
 insert into automation.sms_suppressions(phone_hash) values('daecc6a756afc5e3afb72983a2f23862de66afc377bf959f162e651edb0c2694');
 if automation.controlled_sms_worker('controlled_sms_claim','{}') is not null then raise exception 'FAIL suppressed recipient';end if;
 delete from automation.sms_suppressions where phone_hash='daecc6a756afc5e3afb72983a2f23862de66afc377bf959f162e651edb0c2694';
 update automation.controlled_sms_test set encrypted_payload=extensions.pgp_sym_encrypt((payload||'{"phone":"+18032460225"}')::text,(select value from private.encryption_key));
 if automation.controlled_sms_worker('controlled_sms_claim','{}') is not null then raise exception 'FAIL alternate destination';end if;
 update automation.controlled_sms_test set encrypted_payload=extensions.pgp_sym_encrypt((payload-'phone')::text,(select value from private.encryption_key));
 if automation.controlled_sms_worker('controlled_sms_claim','{}') is not null then raise exception 'FAIL missing destination';end if;
 update automation.controlled_sms_test set encrypted_payload=extensions.pgp_sym_encrypt((payload||'{"body":"Different disposable body"}')::text,(select value from private.encryption_key));
 if automation.controlled_sms_worker('controlled_sms_claim','{}') is not null then raise exception 'FAIL altered body';end if;
 update automation.controlled_sms_test set encrypted_payload=extensions.pgp_sym_encrypt(payload::text,(select value from private.encryption_key));
 denied:=false;begin update automation.controlled_sms_test set consent_scope='program';exception when check_violation then denied:=true;end;
 if not denied then raise exception 'FAIL recurring consent scope';end if;
 r:=automation.controlled_sms_worker('controlled_sms_claim','{}');attempt:=(r->>'attemptId')::uuid;
 if attempt is null or r->>'phone'<>'+18032460224' or r->>'body'<>payload->>'body' then raise exception 'FAIL reserved fixture';end if;
 if automation.controlled_sms_worker('controlled_sms_claim','{}') is not null then raise exception 'FAIL repeated claim';end if;
 perform automation.controlled_sms_worker('controlled_sms_result',jsonb_build_object('attemptId',attempt,'state','unknown','errorCode','provider_outcome_unknown'));
 if automation.controlled_sms_worker('controlled_sms_claim','{}') is not null then raise exception 'FAIL retry uncertain outcome';end if;
 perform automation.controlled_sms_worker('controlled_sms_result',jsonb_build_object('attemptId',attempt,'state','delivered','providerSid','SM11111111111111111111111111111111'));
 perform automation.controlled_sms_worker('controlled_sms_result',jsonb_build_object('attemptId',attempt,'state','queued','providerSid','SM11111111111111111111111111111111'));
 if not exists(select 1 from automation.controlled_sms_test where state='delivered' and delivery_status='delivered') then raise exception 'FAIL controlled callback ordering';end if;
 if exists(select 1 from automation.controlled_sms_test where audit::text like '%'||(payload->>'body')||'%') then raise exception 'FAIL body in audit';end if;
 if has_table_privilege('anon','automation.controlled_sms_test','SELECT') or has_table_privilege('authenticated','automation.controlled_sms_test','SELECT') then raise exception 'FAIL employee table exposure';end if;
 if has_function_privilege('anon','automation.controlled_sms_worker(text,jsonb)','EXECUTE') or has_function_privilege('authenticated','automation.controlled_sms_worker(text,jsonb)','EXECUTE') then raise exception 'FAIL helper exposure';end if;
 update automation.settings set worker_token_hash=encode(extensions.digest('isolated-controlled-worker-token-12345','sha256'),'hex');
 if automation.worker('isolated-controlled-worker-token-12345','controlled_sms_inspect')->>'state'<>'delivered' then raise exception 'FAIL existing worker routing';end if;
 if (select mode from automation.settings)<>'dry_run' or exists(select 1 from automation.sms_consents) then raise exception 'FAIL general activation/consent mutation';end if;
end $$;
select 'PASS: one fixed recipient/fixture, separate approval, STOP, one-shot reservation, uncertainty fence, callback routing, private audits and unchanged general dispatch' result;
