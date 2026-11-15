import test from 'node:test';import assert from 'node:assert/strict';
import {orderedUnits,classifyUnit,fetchWalkthroughSource,WALKTHROUGH_ISSUES} from '../lib/walkthrough.mjs';
import {readInventoryRoute} from '../lib/inventory-filters.mjs';
test('Cubby sequence is preserved; missing/tied positions use natural numbers without modifying input',()=>{
 const rows=[{unitId:'a',name:'010',walkthroughOrder:2},{unitId:'b',name:'2',walkthroughOrder:1},{unitId:'c',name:'001',walkthroughOrder:2},{unitId:'d',name:'X10'},{unitId:'e',name:'x2'}];
 assert.deepEqual(orderedUnits(rows).map(x=>x.unitId),['b','c','a','e','d']);assert.equal(rows[0].unitId,'a');
});
test('auction takes priority; occupied/vacant/overlocked/unknown use verified state',()=>{
 assert.equal(classifyUnit({free:false,leaseId:'l',overlocked:true},{leaseId:'l',overlockNeeded:true},{status:'LISTED'}),'auction');
 assert.equal(classifyUnit({free:false,leaseId:'l',overlocked:false},{leaseId:'l',moveOutDate:null}),'occupied');
 assert.equal(classifyUnit({free:true,leaseId:null},null),'vacant');
 assert.equal(classifyUnit({free:false,leaseId:'l'},{leaseId:'l',overlockNeeded:true}),'overlock');
 assert.equal(classifyUnit({free:false,leaseId:'l'},null),'unknown');
 assert.equal(classifyUnit({free:true,leaseId:'l'},null),'unknown');
});
const link={sourceFacilityId:'fac_1'};
function client(alter={}){return {search:async(path,where,expansions)=>{
 assert.equal(where.facilityId,'fac_1');
 if(path==='facilities/search')return {facilities:[{facilityId:'fac_1',timeZone:'America/New_York'}]};
 if(path==='units/search')return {units:alter.units||[{facilityId:'fac_1',unitId:'u2',name:'2',free:true,walkthroughOrder:2},{facilityId:'fac_1',unitId:'u1',name:'1',free:false,leaseId:'l',walkthroughOrder:1}]};
 if(path==='leases/search'){assert.deepEqual(expansions,['customer']);return {leases:[{leaseId:'l',facilityId:'fac_1',customerId:'c',unitId:'u1',moveOutDate:null}],customers:[{customerId:'c',name:'Test tenant',contact:{phone:'PRIVATE'},dateOfBirth:'PRIVATE'}]};}
 return {auctions:[{auctionedLeases:[{unitId:'u1',status:'LISTED'}]}]};
}}}
test('read-only facility source retains order and auction/tenant names without contact details',async()=>{
 const r=await fetchWalkthroughSource(client(),link);assert.equal(r.ordering,'cubby');assert.deepEqual(r.units.map(u=>u.label),['1','2']);assert.equal(r.units[0].kind,'auction');assert.equal(r.units[0].tenantName,'Test tenant');assert.ok(!JSON.stringify(r).includes('PRIVATE'));
});
test('cross-facility and ambiguous source identities fail closed',async()=>{
 await assert.rejects(()=>fetchWalkthroughSource(client({units:[{facilityId:'other',unitId:'u',name:'1'}]}),link));
 await assert.rejects(()=>fetchWalkthroughSource(client({units:[{facilityId:'fac_1',unitId:'u',name:'1'},{facilityId:'fac_1',unitId:'u',name:'2'}]}),link));
});
test('only six approved issues; manager routing retains authorized scope',()=>{
 assert.deepEqual(WALKTHROUGH_ISSUES,['Moved Out','No tenant lock','Unexpected Lock','Incorrect Overlock','Door/Latch Damage','Other']);
 assert.deepEqual(readInventoryRoute('?view=walkthrough&facility=other','employee',[{id:'authorized'}],'authorized'),{scope:'authorized',view:'walkthrough',filter:''});
});
