import test from 'node:test';
import assert from 'node:assert/strict';
import {verifyPreactivation} from '../lib/automation/preactivation-verification.mjs';
import {fetchLeaseFacts} from '../lib/automation/cubby.mjs';
import {verifyCampaignTemplates} from '../lib/automation/twilio-verification.mjs';
import {renderMessage} from '../lib/automation/policy.mjs';

function fixture(){
 const stamp=new Date().toISOString(),reference={leaseId:'lease_fixture',facilityId:'fac_fixture',unitId:'unit_fixture',customerId:'customer_fixture'};
 const lease={...reference,createdAt:stamp,updatedAt:stamp,moveOutDate:null,moveInDate:'2026-01-01',paid:true,overlockNeeded:false};
 const data={
  'leases/search':{leases:[lease],compliances:[{leaseId:reference.leaseId,documents:[{status:'APPROVED'}]}]},
  'units/search':{units:[{unitId:reference.unitId,facilityId:reference.facilityId,leaseId:reference.leaseId,free:false,name:'PRIVATE-UNIT'}]},
  'customers/search':{customers:[{customerId:reference.customerId,contact:{phone:'+17045550100'},communicationPreferences:{sms:{suppressed:false}}}]},
  'ledgers/search':{ledgers:[{leaseId:reference.leaseId,balances:{totalDue:0}}]},
  'payments/search':{payments:[{createdAt:stamp,status:'SUCCEEDED'}]},
  'auctions/search':{auctions:[]},'facilities/search':{facilities:[{facilityId:reference.facilityId,name:'PRIVATE-FACILITY',timeZone:'America/New_York'}]},
  'delinquency-exemptions/search':{delinquencyExemptions:[]}
 };
 const client={search:async resource=>data[resource]};
 const store={call:async(op)=>{
  assert.ok(['links','snapshot_get'].includes(op),'diagnostic must not write or decrypt');
  return op==='links'?[{orgId:'org_fixture',sourceFacilityId:reference.facilityId}]:null;
 }};
 const env={CUBBY_ORGANIZATION_ID:'org_fixture',CUBBY_OPERATIONAL_ACCESS_VERIFIED:'true',LOCKS_LIVE_SMS_ENABLED:'false'};
 const context={policy:{evaluationStartedAt:'2026-01-01T00:00:00Z'},assignments:[{id:'private-assignment',lockId:'private-lock',lockVersion:3,lockStatus:'vacant',type:'vacant',facilityId:reference.facilityId,unitId:reference.unitId,assignedAt:'2026-01-01T00:00:00Z',releasedAt:null}],encryptedCombinationPresent:true};
 return {reference,data,client,store,env,context};
}
test('bounded production shadow observation uses only reads and returns no identities, phones or combinations',async()=>{
 const f=fixture();
 const result=await verifyPreactivation(f.env,{...f,samples:[{reference:f.reference,context:f.context}]});
 assert.deepEqual(result.counts,{observed:1,eligible:0,blocked:1});
 assert.equal(result.results[0].reason,'consent_unverified');
 assert.equal(result.results[0].checks.repeatedDecisionStable,true);
 assert.equal(result.results[0].checks.currentCombinationVersionBound,true);
 assert.equal(result.databaseWrites,0);assert.equal(result.combinationDecryptions,0);assert.equal(result.smsSubmitted,0);
 const output=JSON.stringify(result);for(const value of ['PRIVATE-',f.reference.leaseId,'+17045550100','private-assignment','private-lock'])assert.ok(!output.includes(value));
});
test('shadow verification refuses live mode, unbounded samples and facilities outside mapped organization',async()=>{
 const f=fixture();
 assert.equal((await verifyPreactivation({...f.env,LOCKS_LIVE_SMS_ENABLED:'true'},{...f,samples:[{}]})).reason,'dry_run_required');
 assert.equal((await verifyPreactivation(f.env,{...f,samples:Array(7).fill({})})).reason,'invalid_sample_count');
 const result=await verifyPreactivation(f.env,{...f,samples:[{reference:{...f.reference,facilityId:'other'}}]});
 assert.equal(result.results[0].reason,'sample_scope_invalid');
});
test('zero-charge completed rental does not infer payment clearance from zero ledger and paid flag',async()=>{
 const f=fixture();f.data['payments/search'].payments=[];
 const r=await fetchLeaseFacts(f.client,f.reference,{contractVerified:true});
 assert.equal(r.facts.rentalAccessReady,true);assert.equal(r.facts.paymentClear,false);assert.equal(r.facts.restrictionsClear,true);
});
test('waived balance with unsuccessful payment remains blocked despite cleared overlock flag',async()=>{
 const f=fixture();f.data['payments/search'].payments[0].status='FAILED';
 const r=await fetchLeaseFacts(f.client,f.reference,{previous:{facts:{active:true,overlockNeeded:true,blockedEpisode:'waiver-fixture'}},contractVerified:true});
 assert.equal(r.kind,'overlock_clearance');assert.equal(r.facts.paymentClear,false);assert.equal(r.facts.releaseAccessReady,false);
});
test('delinquency exemption never overrides outstanding balance or unpaid source flag',async()=>{
 const f=fixture();f.data['leases/search'].leases[0].paid=false;f.data['ledgers/search'].ledgers[0].balances.totalDue=100;
 f.data['delinquency-exemptions/search'].delinquencyExemptions=[{leaseId:f.reference.leaseId,pauseOverlock:true}];
 const r=await fetchLeaseFacts(f.client,f.reference,{previous:{facts:{active:true,overlockNeeded:true,blockedEpisode:'exemption-fixture'}},contractVerified:true});
 assert.equal(r.facts.paymentClear,false);assert.equal(r.facts.restrictionsClear,false);assert.equal(r.facts.releaseAccessReady,false);
});
test('a later pending payment never qualifies on an earlier successful transaction alone',async()=>{
 const f=fixture();f.data['payments/search'].payments=[{createdAt:'2026-01-01T00:00:00Z',status:'SUCCEEDED'},{createdAt:'2026-01-02T00:00:00Z',status:'PENDING'}];
 const r=await fetchLeaseFacts(f.client,f.reference,{contractVerified:true});assert.equal(r.facts.paymentClear,false);
});
test('submitted campaign inspection compares renderer without returning provider text or changing registration',async()=>{
 const data={facility:'[Facility Name]',unit:'[Unit]',serial:'[Serial]',combination:'[Combination]',returnInstructions:'[Approved Return Location]'};
 const r=await verifyCampaignTemplates({TWILIO_ACCOUNT_SID:'fixture-account',TWILIO_AUTH_TOKEN:'fixture-only',TWILIO_MESSAGING_SERVICE_SID:'fixture-service'},
  {clientFactory:()=>({messaging:{v1:{services:()=>({usAppToPerson:{list:async()=>[{campaignStatus:'IN_PROGRESS',usAppToPersonUsecase:'ACCOUNT_NOTIFICATION',messageSamples:[renderMessage('overlock_clearance',data),renderMessage('new_rental',data)],messageFlow:'private registration narrative'}]}})}}})});
 assert.equal(r.campaigns[0].productionOverlockExactSample,true);assert.equal(r.campaigns[0].productionRentalExactSample,true);
 assert.equal(r.campaignWrites,0);assert.equal(r.smsSubmitted,0);assert.ok(!JSON.stringify(r).includes('private registration narrative'));assert.ok(!JSON.stringify(r).includes('[Combination]'));
});
