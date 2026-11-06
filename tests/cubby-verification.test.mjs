import test from 'node:test';import assert from 'node:assert/strict';
import {verifyCubby} from '../lib/automation/cubby-verification.mjs';
test('operational verification reports read permissions without secrets or customer data',async()=>{
 const calls=[],lease={leaseId:'lease_fixture',facilityId:'fac_fixture',unitId:'unit_fixture',customerId:'customer_fixture',moveOutDate:null,updatedAt:new Date().toISOString()};
 const responses={'facilities/search':{facilities:[{facilityId:'fac_fixture',timeZone:'America/New_York'}]},'units/search':{units:[{unitId:'unit_fixture'}]},'leases/search':{leases:[lease],compliances:[]},'customers/search':{customers:[{customerId:'customer_fixture',name:'PRIVATE-NAME',contact:{phone:'PRIVATE-PHONE'},communicationPreferences:{sms:{suppressed:false}}}]},'payments/search':{payments:[{status:'SUCCEEDED'}]},'ledgers/search':{ledgers:[{leaseId:'lease_fixture',balances:{totalDue:0}}]},'auctions/search':{auctions:[]},'delinquency-exemptions/search':{delinquencyExemptions:[]}};
 const result=await verifyCubby({CUBBY_API_KEY:'PRIVATE-TOKEN',CUBBY_ORGANIZATION_ID:'org_fixture',LOCKS_LIVE_SMS_ENABLED:'false'},{store:{call:async()=>[{orgId:'org_fixture',sourceFacilityId:'fac_fixture'}]},client:{search:async(resource)=>{calls.push(resource);return responses[resource]}}});
 assert.equal(result.authenticationVerified,true);assert.equal(result.state,'connected');assert.equal(result.facilityScope.allMappedAccessible,true);assert.equal(result.smsSendingEnabled,false);assert.equal(result.eventVisibilityLatencyMeasured,false);assert.equal(JSON.stringify(result).includes('PRIVATE-'),false);assert.ok(calls.every(x=>x.endsWith('/search')));
});
test('missing or incorrect credential types never make an API request',async()=>{
 for(const key of [undefined,'{"type":"service_account"}','Bearer incorrect-format']){
  const result=await verifyCubby({CUBBY_API_KEY:key},{client:{search:()=>{throw Error('must not call')}}});assert.equal(result.authenticationVerified,false);
 }
});
