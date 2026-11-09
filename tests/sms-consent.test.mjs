import test from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';
import {tenantInput,requestChallenge} from '../lib/automation/tenant-security.mjs';
import {REQUEST_CONSENT_VERSION,REQUEST_CONSENT_TEXT,inboundReply} from '../lib/automation/sms-disclosure.mjs';
import {processTenantRequest} from '../lib/automation/tenant-requests.mjs';
import {verifyCubbyConsent} from '../lib/automation/cubby-consent-verification.mjs';

test('only literal affirmative checkbox input records the server-selected disclosure',()=>{
 const now=Date.now(),secret='fixture-only',base={facility:'a'.repeat(24),unit:'001A',phone:'7045550100',requestKey:randomUUID(),challenge:requestChallenge(secret,now-3000),consentVersion:'untrusted-client-version'};
 for(const choice of [undefined,false,'true',1,null]){const r=tenantInput({...base,smsConsent:choice},{secret,ip:'192.0.2.1',now});assert.equal(r.smsConsent,false)}
 const r=tenantInput({...base,smsConsent:true},{secret,ip:'192.0.2.1',now});assert.equal(r.smsConsent,true);assert.equal(r.consentVersion,REQUEST_CONSENT_VERSION);assert.ok(!JSON.stringify(r).includes('7045550100'));
 assert.match(REQUEST_CONSENT_TEXT,/one transactional text/);assert.match(REQUEST_CONSENT_TEXT,/does not enroll me in recurring/);
});
test('declining SMS never reaches source verification or consent promotion',async()=>{
 const calls=[];const rt={store:{call:async(op,p)=>{calls.push(op);if(op==='tenant_get')return {expiresAt:new Date(Date.now()+900000).toISOString(),smsConsent:false};return null}},client:{search:()=>{throw Error('must not call')}},env:{}};
 assert.equal((await processTenantRequest(rt,'fixture')).reason,'sms_not_requested');assert.deepEqual(calls,['tenant_get','tenant_finish']);
});
test('an affirmative but unverified recipient cannot create consent',async()=>{
 const calls=[];const rt={store:{call:async op=>{calls.push(op);if(op==='tenant_get')return {expiresAt:new Date(Date.now()+900000).toISOString(),smsConsent:true,sourceOrgId:'org_TEST',sourceFacilityId:'fac_TEST',unit:'001A'};if(op==='tenant_source_claim')return true;return null}},client:{search:async()=>({units:[]})},env:{CUBBY_API_KEY:'fixture',CUBBY_ORGANIZATION_ID:'org_TEST',CUBBY_OPERATIONAL_ACCESS_VERIFIED:'true',CUBBY_RATE_LIMIT_VERIFIED:'true'}};
 assert.equal((await processTenantRequest(rt,'fixture')).state,'blocked');assert.ok(!calls.includes('tenant_consent_verify'));assert.ok(!calls.includes('tenant_enqueue'));
});
test('consent inspection returns field summaries, never identities or inferred opt-in',async()=>{
 const report=await verifyCubbyConsent({CUBBY_ORGANIZATION_ID:'org_TEST'},{store:{call:async()=>[{orgId:'org_TEST',sourceFacilityId:'fac_TEST'}]},client:{search:async()=>({customers:[{customerId:'PRIVATE-ID',contact:{phone:'+17045550100'},communicationPreferences:{sms:{marketing:true,suppressed:false,suppressionReason:null}}}]})}});
 assert.deepEqual(report.smsFields,['marketing','suppressed','suppressionReason']);assert.equal(report.affirmativeConsentInferred,false);assert.equal(report.consentsCreated,0);assert.ok(!JSON.stringify(report).includes('PRIVATE-ID'));assert.ok(!JSON.stringify(report).includes('+17045550100'));
});
test('HELP is branded, escapes XML, honors the live gate and avoids duplicate Advanced Opt-Out replies',()=>{
 assert.equal(inboundReply({Body:'HELP'}),'<Response/>');assert.equal(inboundReply({Body:'HELP',OptOutType:'HELP'},{liveEnabled:true}),'<Response/>');assert.equal(inboundReply({Body:'START'},{liveEnabled:true}),'<Response/>');
 const xml=inboundReply({Body:'HELP'},{liveEnabled:true});assert.match(xml,/My Storage Locks/);assert.match(xml,/&amp;/);assert.ok(!/combination\s+\d/.test(xml));
});
