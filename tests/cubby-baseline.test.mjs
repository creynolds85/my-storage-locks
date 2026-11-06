import test from 'node:test';import assert from 'node:assert/strict';
import {pollOperationalData} from '../lib/automation/worker.mjs';
test('initial API baseline scopes active records and bounds checkpoint concurrency before completion',async()=>{
 let inFlight=0,maxInFlight=0,saved=0,finished=false;const reads=[];
 const units=Array.from({length:17},(_,i)=>({unitId:'unit_'+i,facilityId:'fac_TEST',name:String(i),leaseId:'lease_'+i}));
 const leases=units.map(u=>({leaseId:u.leaseId,unitId:u.unitId,facilityId:u.facilityId,customerId:'customer_TEST',moveOutDate:null,updatedAt:new Date().toISOString(),overlockNeeded:false}));
 const result=await pollOperationalData({env:{CUBBY_ORGANIZATION_ID:'org_TEST'},client:{search:async(resource,where)=>{reads.push([resource,where]);if(resource==='facilities/search')return {facilities:[{facilityId:'fac_TEST',timeZone:'America/New_York'}]};if(resource==='units/search')return {units};if(resource==='leases/search'){assert.match(where.activeOnOrAfter,/^\d{4}-\d{2}-\d{2}$/);return {leases}}if(resource==='customers/search'){assert.equal(where.lease,'ACTIVE');return {customers:[]}}throw Error('unexpected read')}},store:{call:async(op,p)=>{
  if(op==='sync_claim')return {cursors:{}};if(op==='links')return [{orgId:'org_TEST',sourceFacilityId:'fac_TEST'}];if(op==='units_save')return {ok:true};
  if(op==='snapshot_save'){assert.equal(p.facts.verified,false);inFlight++;maxInFlight=Math.max(maxInFlight,inFlight);await new Promise(resolve=>setTimeout(resolve,1));saved++;inFlight--;return {ok:true}}
  if(op==='sync_finish'){assert.equal(p.ok,true);assert.equal(saved,17);assert.equal(inFlight,0);finished=true;return {ok:true}}
  throw Error('unexpected write');
 }}});
 assert.equal(result.state,'synchronized');assert.equal(maxInFlight,8);assert.equal(finished,true);assert.equal(reads.length,4);
});
