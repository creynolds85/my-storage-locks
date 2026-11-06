import test from 'node:test';import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {requestChallenge,tenantInput,TENANT_RESPONSE} from '../lib/automation/tenant-security.mjs';
import {digest,evaluateNotification,evaluateTenantRequest} from '../lib/automation/policy.mjs';
import {processTenantRequest} from '../lib/automation/tenant-requests.mjs';
import {drainInbox,drainOutbox} from '../lib/automation/worker.mjs';
const now=Date.now(),iso=new Date(now).toISOString(),earlier=new Date(now-60000).toISOString();
const env={CUBBY_API_KEY:'fixture-only',CUBBY_ORGANIZATION_ID:'org_TEST',CUBBY_OPERATIONAL_ACCESS_VERIFIED:'true',CUBBY_RATE_LIMIT_VERIFIED:'true',LOCKS_LIVE_SMS_ENABLED:'false'};
function fixture(type='vacant'){
 const request={id:randomUUID(),facilityId:'local-facility',sourceOrgId:'org_TEST',sourceFacilityId:'fac_TEST',unit:'001A',unitHash:'fixture-unit-hash',phoneDigest:digest('+17045550100'),expiresAt:new Date(now+900000).toISOString()};
 const facts={verified:true,verifiedAt:iso,occurredAt:earlier,facilityId:'fac_TEST',unitId:'unit_TEST',leaseId:'lease_TEST',customerId:'customer_TEST',active:true,paymentClear:true,overlockNeeded:false,auctionClear:true,restrictionsClear:true,rentalCompleted:true,rentalAccessReady:true,releaseAccessReady:true,requirementsSatisfied:true,moveInAllowed:true,clearanceTransition:true,episodeId:'episode_TEST'};
 const assignment={id:'assignment_TEST',lockId:'lock_TEST',lockVersion:1,lockStatus:type,type,facilityId:'fac_TEST',unitId:'unit_TEST',releasedAt:null,assignedAt:null};
 const recipient={phone:'+17045550100',customerId:'customer_TEST',verified:true,suppressed:false};
 const consent={proofId:'consent_TEST',customerId:'customer_TEST',phone:'+17045550100',purpose:'lock_access',valid:true,suppressed:false};
 const input={request,contextFacilityId:'local-facility',kind:type==='overlock'?'overlock_clearance':'new_rental',facts,assignments:[assignment],recipient,consent,policy:{evaluationStartedAt:new Date(now-3600000).toISOString(),maxAgeSeconds:120},now};
 return {request,facts,assignment,recipient,consent,input};
}
test('public intake validates signed challenges, preserves unit zeros, hashes submitted contact details',()=>{
 const secret='fixture-secret-only',challenge=requestChallenge(secret,now-3000),body={facility:'a'.repeat(24),unit:'001A',phone:'704-555-0100',requestKey:randomUUID(),challenge};
 const good=tenantInput(body,{secret,ip:'192.0.2.1',now});assert.equal(good.unit,'001A');assert.equal(good.phoneDigest,digest('+17045550100'));assert.ok(!JSON.stringify(good).includes('704-555-0100'));assert.ok(!JSON.stringify(good).includes('192.0.2.1'));
 for(const edit of [{website:'bot'},{challenge:{...challenge,signature:'b'.repeat(64)}},{challenge:requestChallenge(secret,now)},{challenge:requestChallenge(secret,now-1900000)},{phone:'x'}])assert.equal(tenantInput({...body,...edit},{secret,ip:'192.0.2.1',now}),null);
 assert.ok(!TENANT_RESPONSE.includes('unit exists'));
});
test('current vacant and cleared overlock tenant requests accept unknown original assignment dates without inventing history',()=>{
 for(const type of ['vacant','overlock']){const f=fixture(type);f.facts.occurredAt='2025-01-01T00:00:00Z';f.facts.clearanceTransition=false;f.facts.rentalCompleted=false;const result=evaluateTenantRequest(f.input);assert.equal(result.eligible,true);assert.equal(result.initiator,'tenant_request');assert.equal(result.phone,f.recipient.phone);}
});
test('legitimate repeat requests get new notification identities after a new verified request',()=>{
 const f=fixture();const a=evaluateTenantRequest(f.input);const b=evaluateTenantRequest({...f.input,request:{...f.request,id:randomUUID()}});assert.notEqual(a.key,b.key);assert.equal(a.key,evaluateTenantRequest(f.input).key);
});
test('incorrect phone, wrong facility, and expired requests cannot authorize delivery',()=>{
 for(const changes of [{phoneDigest:digest('+17045550101')},{facilityId:'other'},{expiresAt:earlier}]){const f=fixture();assert.equal(evaluateTenantRequest({...f.input,request:{...f.request,...changes}}).eligible,false)}
});
test('unpaid, pending, restricted, incomplete and stale source facts deny requests',()=>{
 for(const changes of [{paymentClear:false},{overlockNeeded:true},{restrictionsClear:false},{auctionClear:false},{requirementsSatisfied:false},{rentalAccessReady:false},{active:false},{verified:false},{verifiedAt:new Date(now-121000).toISOString()}]){const f=fixture();assert.equal(evaluateTenantRequest({...f.input,facts:{...f.facts,...changes}}).eligible,false)}
});
test('auction, tenant-held, unclassified, damaged, missing and ambiguous physical locks stay excluded',()=>{
 for(const type of ['auction','tenant_held','unclassified','damaged','missing'])assert.equal(evaluateTenantRequest(fixture(type).input).eligible,false);
 const f=fixture();assert.equal(evaluateTenantRequest({...f.input,assignments:[]}).eligible,false);assert.equal(evaluateTenantRequest({...f.input,assignments:[f.assignment,{...f.assignment,id:'second'}]}).eligible,false);
});
test('consent evidence, source phone verification and suppression are mandatory',()=>{
 for(const input of [{consent:null},{consent:{valid:false}},{consent:{suppressed:true}},{recipient:{verified:false}},{recipient:{suppressed:true}}]){const f=fixture();const key=Object.keys(input)[0];assert.equal(evaluateTenantRequest({...f.input,[key]:input[key]?{...f.input[key],...input[key]}:null}).eligible,false)}
});
test('automatic and tenant policies remain distinct; business hours do not authorize either path',()=>{
 const f=fixture();f.assignment.assignedAt=new Date(now-86400000).toISOString();assert.equal(evaluateNotification(f.input).eligible,true);
 f.facts.clearanceTransition=false;f.input.kind='overlock_clearance';f.assignment.type=f.assignment.lockStatus='overlock';assert.equal(evaluateNotification(f.input).eligible,false);assert.equal(evaluateTenantRequest(f.input).eligible,true);
 for(const hour of [12,23]){const x=fixture();const stamp=Date.parse('2026-11-06T'+String(hour).padStart(2,'0')+':00:00Z');x.input.now=stamp;x.facts.verifiedAt=new Date(stamp).toISOString();x.request.expiresAt=new Date(stamp+900000).toISOString();assert.equal(evaluateTenantRequest(x.input).eligible,true)}
});
function runtimeFixture(type='vacant'){
 const f=fixture(type),calls=[],options={paid:true,phone:'+17045550100',docs:true,sourceFailure:false,ambiguous:false};
 const context={facilityId:f.request.facilityId,assignments:[f.assignment],consent:f.consent,policy:f.input.policy};
 const client={search:async(resource)=>{if(options.sourceFailure)throw Error('source outage fixture');switch(resource){
 case 'units/search':return {units:[{unitId:'unit_TEST',facilityId:'fac_TEST',leaseId:'lease_TEST',name:'001A',free:false}]};
 case 'leases/search':return {leases:[{leaseId:'lease_TEST',unitId:'unit_TEST',facilityId:'fac_TEST',customerId:'customer_TEST',moveOutDate:null,paid:options.paid,moveInDate:'2026-01-01',createdAt:earlier,updatedAt:iso,overlockNeeded:false}],compliances:[{leaseId:'lease_TEST',documents:[{status:options.docs?'APPROVED':'PENDING'}]}]};
 case 'customers/search':return {customers:[{customerId:'customer_TEST',contact:{phone:options.phone},communicationPreferences:{sms:{suppressed:false}}}]};
 case 'ledgers/search':return {ledgers:[{leaseId:'lease_TEST',balances:{totalDue:options.paid?0:100}}]};
 case 'payments/search':return {payments:[{createdAt:iso,status:options.paid?'SUCCEEDED':'APPROVING'}]};
 case 'auctions/search':return {auctions:[]};case 'facilities/search':return {facilities:[{facilityId:'fac_TEST',name:'Fixture facility',timeZone:'America/New_York'}]};default:throw Error(resource);
 }}};
 const store={call:async(op,p={})=>{calls.push({op,p});switch(op){case 'tenant_source_claim':return true;case 'tenant_get':return f.request;case 'snapshot_get':return {facts:{active:true,overlockNeeded:false}};case 'context':return {...context,assignments:options.ambiguous?[f.assignment,{...f.assignment,id:'second'}]:[f.assignment]};case 'tenant_verify':return {verified:true};case 'tenant_enqueue':return {id:'notification_TEST',state:'dry_run'};case 'inbox_claim':if(calls.filter(c=>c.op==='inbox_claim').length===1)return {id:'inbox_TEST',eventType:'tenant_request',reference:{requestId:f.request.id}};return null;default:return null;}}};
 return {rt:{env:{...env},client,store},f,calls,options};
}
test('tenant request traverses the existing durable inbox and verification path without employee login',async()=>{
 const {rt,calls}=runtimeFixture();const r=await drainInbox(rt,{limit:1});assert.deepEqual(r.notificationIds,['notification_TEST']);assert.ok(calls.some(c=>c.op==='inbox_finish'&&c.p.ok));assert.ok(calls.some(c=>c.op==='tenant_enqueue'&&c.p.initiator==='tenant_request'));assert.ok(!calls.some(c=>c.op==='reveal_combination'||c.op==='mutate_lock'));
});
test('source recipient changes and pending payment block before enqueue; source outages stay retryable',async()=>{
 for(const edit of [{phone:'+17045550101'},{paid:false},{docs:false},{ambiguous:true}]){const {rt,calls,options,f}=runtimeFixture();Object.assign(options,edit);const r=await processTenantRequest(rt,f.request.id);assert.equal(r.state,'blocked');assert.ok(!calls.some(c=>c.op==='tenant_enqueue'))}
 const {rt,calls,options}=runtimeFixture();options.sourceFailure=true;await drainInbox(rt,{limit:1});assert.ok(calls.some(c=>c.op==='inbox_finish'&&c.p.ok===false));
});
test('missing operational permissions fail closed and are recorded through the same queue',async()=>{
 const {rt,calls}=runtimeFixture();delete rt.env.CUBBY_API_KEY;await drainInbox(rt,{limit:1});assert.ok(calls.some(c=>c.op==='inbox_claim'&&c.p.tenantOnly));assert.ok(calls.some(c=>c.op==='tenant_finish'&&c.p.reason==='operational_source_unverified'));assert.ok(!calls.some(c=>c.op==='snapshot_save'));
});
test('live disabled prevents any provider call; provider failures and uncertain outcomes use the existing status recorder',async()=>{
 const x=runtimeFixture();let sends=0;x.rt.sender={ready:()=>true,send:async()=>{sends++;return {state:'failed',errorCode:'fixture-failure'}}};assert.deepEqual(await drainOutbox(x.rt),{state:'disabled',sent:0});assert.equal(sends,0);
 for(const providerResult of [{state:'failed',errorCode:'fixture-failure'},{state:'unknown',errorCode:'provider_outcome_unknown'}]){
  const f=runtimeFixture();f.rt.env.LOCKS_LIVE_SMS_ENABLED='true';const original=f.rt.store.call;f.rt.store.call=async(op,p)=>{if(op==='outbox_peek')return {id:'notification_TEST',initiator:'tenant_request',tenantRequestId:f.f.request.id};if(op==='outbox_claim')return {id:'notification_TEST',attemptId:'attempt_TEST',kind:'new_rental',facility:'Fixture',unit:'001A',serial:'FIXTURE',combination:'DISPOSABLE-TEST-ONLY',returnInstructions:'test drop box',phone:'+17045550100'};return original(op,p)};f.rt.sender={ready:()=>true,send:async()=>providerResult};await drainOutbox(f.rt,{limit:1});assert.ok(f.calls.some(c=>c.op==='outbox_result'&&c.p.state===providerResult.state));assert.ok(!JSON.stringify(f.calls).includes('DISPOSABLE-TEST-ONLY'));
 }
});
test('a changed assignment or combination blocks dispatch at the existing final database claim',async()=>{
 const f=runtimeFixture();f.rt.env.LOCKS_LIVE_SMS_ENABLED='true';let sent=0;const original=f.rt.store.call;f.rt.store.call=async(op,p)=>op==='outbox_peek'?{id:'notice',initiator:'tenant_request',tenantRequestId:f.f.request.id}:op==='outbox_claim'?{cancelled:true}:original(op,p);f.rt.sender={ready:()=>true,send:async()=>{sent++;return {state:'delivered'}}};await drainOutbox(f.rt,{limit:1});assert.equal(sent,0);
});
