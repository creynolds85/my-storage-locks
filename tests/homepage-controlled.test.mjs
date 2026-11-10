import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {legacyManagerDestination} from '../lib/manager-routing.mjs';
import {createTwilioSender} from '../lib/automation/twilio.mjs';
import {controlledTest} from '../lib/automation/controlled-test.mjs';
import {CONTROLLED_FIXTURE_ID,CONTROLLED_PHONE,CONTROLLED_PHONE_HASH,CONTROLLED_BODY_HASH} from '../lib/automation/controlled-test-identity.mjs';

const source=path=>readFileSync(new URL('../'+path,import.meta.url),'utf8');
test('public home and legacy request URL reuse the same tenant form; managers have separate entry points',()=>{
 for(const path of ['app/page.tsx','app/get-combination/page.tsx'])assert.match(source(path),/TenantRequestPage/);
 assert.ok(!source('app/page.tsx').includes('LockManager'));
 for(const path of ['app/login/page.tsx','app/dashboard/page.tsx'])assert.match(source(path),/ManagerPage/);
 assert.match(source('components/tenant-combination-request.tsx'),/tenant-manager-link" href="\/login">Manager Login/);
 assert.match(source('components/lock-manager.tsx'),/emailRedirectTo:window.location.origin\+MANAGER_LOGIN_PATH/);
 assert.match(source('components/lock-manager.tsx'),/redirectTo:window.location.origin\+MANAGER_LOGIN_PATH/);
});
test('legacy auth and inventory links preserve callback tokens and scope without redirecting ordinary tenant requests',()=>{
 assert.equal(legacyManagerDestination('https://mystoragelocks.com/'),null);
 assert.equal(legacyManagerDestination('https://mystoragelocks.com/?facility=public'),null);
 assert.equal(legacyManagerDestination('https://mystoragelocks.com/#access_token=fixture&type=recovery'),'/login#access_token=fixture&type=recovery');
 assert.equal(legacyManagerDestination('https://mystoragelocks.com/?code=fixture'),'/login?code=fixture');
 assert.equal(legacyManagerDestination('https://mystoragelocks.com/?view=inventory&facility=fixture&status=other'),'/dashboard?view=inventory&facility=fixture&status=other');
});
function fixture(){
 // The secret-bearing isolated payload is supplied only by the local fixture
 // preparation, never checked into source or read from production inventory.
 const body=process.env.CONTROLLED_FIXTURE_TEST_BODY||'placeholder-not-authorized';
 const now=Date.now(),submissions=[];
 const env={LOCKS_LIVE_SMS_ENABLED:'false',LOCKS_CONTROLLED_SMS_TEST_ENABLED:'true',TWILIO_ACCOUNT_SID:'fixture-account',TWILIO_AUTH_TOKEN:'fixture-auth',TWILIO_API_KEY_SID:'fixture-key',TWILIO_API_KEY_SECRET:'fixture-secret',TWILIO_MESSAGING_SERVICE_SID:'fixture-service'};
 const service={fetch:async()=>({accountSid:env.TWILIO_ACCOUNT_SID,friendlyName:'My Storage Locks Access Notifications'}),usAppToPerson:{list:async()=>[{campaignStatus:'VERIFIED'}]},phoneNumbers:{list:async()=>[{sid:'fixture-number',phoneNumber:'+15005550006'}]}};
 const sender=createTwilioSender(env,{clientFactory:()=>({messaging:{v1:{services:()=>service}},incomingPhoneNumbers:()=>({fetch:async()=>({accountSid:env.TWILIO_ACCOUNT_SID,phoneNumber:'+15005550006',capabilities:{sms:true}})}),messages:{create:async p=>{submissions.push(p);return {sid:'SM'+'1'.repeat(32),status:'queued'}}}})});
 const claim={fixtureId:CONTROLLED_FIXTURE_ID,fixtureVersion:1,scope:'single_controlled_test',phone:CONTROLLED_PHONE,phoneHash:CONTROLLED_PHONE_HASH,body,bodyHash:CONTROLLED_BODY_HASH,reserved:true,suppressed:false,attemptId:'12345678-1234-1234-1234-123456789abc',sendApprovedAt:new Date(now-1000).toISOString(),approvalExpiresAt:new Date(now+60000).toISOString(),suppressionCheckedAt:new Date(now).toISOString()};
 return {env,sender,claim,submissions,service};
}
test('final provider boundary rejects every other recipient, body, fixture, scope and approval even with sender verified',async()=>{
 const f=fixture();assert.equal(await f.sender.verifyControlledSender(),true);
 for(const patch of [{phone:'+18032460225'},{phone:'8032460224'},{phone:undefined},{phone:CONTROLLED_PHONE+'0'},{body:'different combination'},{fixtureId:'other'},{fixtureVersion:2},{scope:'program'},{reserved:false},{suppressed:true},{sendApprovedAt:null},{approvalExpiresAt:new Date(0).toISOString()},{suppressionCheckedAt:new Date(0).toISOString()}]){
  assert.equal((await f.sender.sendControlledTest({...f.claim,...patch})).state,'failed');
 }
 assert.equal(f.submissions.length,0);
});
test('only the pinned isolated fixture can reach a stub provider and general dispatch remains disabled',{skip:!process.env.CONTROLLED_FIXTURE_TEST_BODY},async()=>{
 const f=fixture();await f.sender.verifyControlledSender();
 assert.equal((await f.sender.sendControlledTest(f.claim)).state,'queued');
 assert.equal(f.submissions.length,1);assert.equal(f.submissions[0].to,CONTROLLED_PHONE);
 assert.equal(f.submissions[0].contentRetention,'discard');assert.match(f.submissions[0].statusCallback,/controlled=1/);
 await f.sender.send({phone:'+18032460225',body:'must not send',attemptId:f.claim.attemptId});assert.equal(f.submissions.length,1);
});
test('controlled SMS requires its separate enable flag and cannot run with general messaging enabled',async()=>{
 for(const patch of [{LOCKS_CONTROLLED_SMS_TEST_ENABLED:undefined},{LOCKS_CONTROLLED_SMS_TEST_ENABLED:'false'},{LOCKS_LIVE_SMS_ENABLED:'true'},{LOCKS_LIVE_SMS_ENABLED:undefined}]){
  const f=fixture();Object.assign(f.env,patch);await f.sender.verifyControlledSender();await f.sender.sendControlledTest(f.claim);assert.equal(f.submissions.length,0);
 }
});
test('failed sender re-verification invalidates a previously verified test sender',async()=>{
 const f=fixture();assert.equal(await f.sender.verifyControlledSender(),true);
 f.service.usAppToPerson.list=async()=>[{campaignStatus:'IN_PROGRESS'}];
 assert.equal(await f.sender.verifyControlledSender(),false);await f.sender.sendControlledTest(f.claim);assert.equal(f.submissions.length,0);
});
test('inspection, missing authorization, STOP and exhausted claims never dispatch or expose fixture payload',async()=>{
 for(const info of [{prepared:true,approved:false,suppressed:false},{prepared:true,approved:true,suppressed:true},{prepared:true,approved:true,suppressed:false}]){
  let sends=0,claims=0;const rt={env:{LOCKS_LIVE_SMS_ENABLED:'false',LOCKS_CONTROLLED_SMS_TEST_ENABLED:'true'},sender:{verifyControlledSender:async()=>true,sendControlledTest:async()=>{sends++;throw Error('must not send')}},store:{call:async op=>{if(op==='controlled_sms_inspect')return info;if(op==='controlled_sms_claim'){claims++;return null}throw Error('unexpected write')}}};
  const inspected=await controlledTest(rt);assert.equal(inspected.smsSubmitted,0);assert.equal(sends,0);assert.equal(claims,0);
  await controlledTest(rt,{dispatch:true});assert.equal(sends,0);
 }
});
