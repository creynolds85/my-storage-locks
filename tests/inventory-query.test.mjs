import test from 'node:test';
import assert from 'node:assert/strict';
import {serialSearch,effectiveInventorySort,fetchInventory,fetchDashboardMatches} from '../lib/inventory-query.mjs';
test('partial search preserves leading zeros and alphanumeric content from the first character',()=>{
 for(const q of ['0','00','N','n63','P86','1111LLL1'])assert.equal(serialSearch(q),q);
 assert.equal(serialSearch('%_*'), '');
});
test('default sorts follow scope and manual choices remain explicit',()=>{
 assert.equal(effectiveInventorySort('default','all',23),'facility_serial');
 assert.equal(effectiveInventorySort('default','all',2),'facility_serial');
 assert.equal(effectiveInventorySort('default','one',23),'serial');
 assert.equal(effectiveInventorySort('default','one',1),'serial');
 for(const explicit of ['serial','updated_at','created_at'])for(const scope of ['all','one'])assert.equal(effectiveInventorySort(explicit,scope,23),explicit);
});
test('queries use the existing signed-in client, pass scope/filter/page boundaries and never request combinations',async()=>{
 const calls=[];const signal=new AbortController().signal;
 const client={rpc:(name,args)=>{calls.push({name,args});return {abortSignal:s=>{assert.equal(s,signal);return Promise.resolve({data:{items:[{serial:'00N63'}],total:201},error:null})}}}};
 const result=await fetchInventory(client,{query:'n',scope:'facility-a',filter:'unavailable',sort:'facility_serial',limit:100,offset:100,signal});
 assert.equal(result.total,201);assert.equal(result.items[0].serial,'00N63');
 assert.deepEqual(calls,[{name:'inventory_listing',args:{p_query:'n',p_facility:'facility-a',p_statuses:['missing','damaged','retired'],p_sort:'facility_serial',p_limit:100,p_offset:100}}]);
 assert.equal(JSON.stringify(calls).includes('combination'),false);
});
test('dashboard search has no status exclusion and all-facility requests remain server-authorized',async()=>{
 let args;const client={rpc:async(name,p)=>{args=p;return{data:{items:[],total:0},error:null}}};
 await fetchInventory(client,{query:'p86',scope:'all',sort:'facility_serial',limit:20});
 assert.equal(args.p_facility,null);assert.equal(args.p_statuses,null);assert.equal(args.p_query,'p86');assert.equal(args.p_limit,20);
});
test('failed inventory requests cannot appear as successful empty results',async()=>{
 const expected=Error('fixture request rejected');await assert.rejects(fetchInventory({rpc:async()=>({error:expected})}),e=>e===expected);
});

test('instant dashboard requests a bounded authorized list without an expensive exact count',async()=>{
 let captured;const client={rpc:async(name,args)=>{captured=args;return{data:{items:[{serial:'1111LLL1'}],total:null,hasMore:true}}}};
 const result=await fetchDashboardMatches(client,{query:'1',scope:'all',sort:'facility_serial'});
 assert.equal(captured.p_exact_count,false);assert.equal(captured.p_limit,20);assert.equal(captured.p_offset,0);assert.equal(captured.p_statuses,null);assert.equal(result.hasMore,true);assert.equal(result.items[0].serial,'1111LLL1');
});
