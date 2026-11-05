import test from 'node:test';
import assert from 'node:assert/strict';
import {inventoryCategories,inventoryFilters,categoryCount,applyStatusFilter,readInventoryRoute,inventoryRouteUrl} from '../lib/inventory-filters.mjs';
const facilities=[{id:'a'},{id:'b'}];
test('six dashboard categories partition the existing statuses without double counting',()=>{
 const counts={available:7,overlock:3,vacant:2,auction:4,missing:5,retired:6};
 assert.equal(inventoryCategories.length,6);
 assert.deepEqual(inventoryCategories.map(c=>c.cardLabel||c.label),['Total Locks','Available','Overlocked','Vacant','Auction','Missing / Damaged']);
 assert.equal(categoryCount(counts,''),27);assert.equal(categoryCount(counts,'unavailable'),11);assert.equal(categoryCount(counts,'available'),7);
 assert.deepEqual(inventoryCategories.slice(1).flatMap(c=>c.statuses).sort(),[...Object.keys(counts),"damaged"].sort());
 assert.equal(categoryCount({},'unavailable'),0);
});
test('combined inventory query includes both unavailable statuses and retains facility constraints',()=>{
 const calls=[];const q={eq:(...args)=>(calls.push(['eq',...args]),q),in:(...args)=>(calls.push(['in',...args]),q)};
 q.eq('facility_id','a');assert.equal(applyStatusFilter(q,'unavailable'),q);
 assert.deepEqual(calls,[['eq','facility_id','a'],['in','status',['missing','damaged','retired']]]);
 calls.length=0;applyStatusFilter(q,'overlock');assert.deepEqual(calls,[['eq','status','overlock']]);
 calls.length=0;applyStatusFilter(q,'');assert.deepEqual(calls,[]);
 for(const status of ['missing','retired']){calls.length=0;applyStatusFilter(q,status);assert.deepEqual(calls,[['eq','status',status]])}
});
test('individual missing and damaged filters stay available with original database values',()=>{
 assert.deepEqual(inventoryFilters.find(c=>c.id==='missing').statuses,['missing']);
 assert.deepEqual(inventoryFilters.find(c=>c.id==='retired').statuses,['retired']);
});
test('admin route preserves all-facility scope and immediately restores combined filter',()=>{
 assert.deepEqual(readInventoryRoute('?view=inventory&status=unavailable&facility=all','admin',facilities,'a'),{view:'inventory',filter:'unavailable',scope:'all'});
});
test('employee route rejects all facilities, unauthorized facility and admin navigation',()=>{
 for(const facility of ['all','b','unknown']){
 const route=readInventoryRoute('?view=admin&status=overlock&facility='+facility,'employee',[facilities[0]],'a');
 assert.deepEqual(route,{scope:'a',view:'dashboard',filter:'overlock'});
 }
 assert.equal(readInventoryRoute('?facility=all','employee',[],'all').scope,'');
});
test('inventory URL round trip preserves card target, facility, unrelated parameters and anchor',()=>{
 const route={view:'inventory',filter:'unavailable',scope:'b'};
 const url=inventoryRouteUrl('https://example.com/?existing=keep#inventory',route);
 assert.equal(url,'/?existing=keep&view=inventory&status=unavailable&facility=b#inventory');
 assert.deepEqual(readInventoryRoute(new URL(url,'https://example.com').search,'admin',facilities,'all'),route);
 const cleared=inventoryRouteUrl('https://example.com'+url,{...route,filter:'',view:'dashboard'});
 assert.equal(cleared,'/?existing=keep&facility=b#inventory');
});
test('real Supabase query builder sends combined status, scope and serial constraints together',async()=>{
 const {createClient}=await import('@supabase/supabase-js');let captured;
 const client=createClient('https://fixture.example.invalid','fixture-public-key',{auth:{persistSession:false},global:{fetch:async(url)=>{captured=new URL(url);return new Response('[]',{headers:{'content-type':'application/json','content-range':'0-0/0'}})}}});
 const {error}=await applyStatusFilter(client.from('locks').select('*',{count:'exact'}).eq('facility_id','a').ilike('serial','%p86%'),'unavailable').order('serial').limit(100);
 assert.equal(error,null);assert.equal(captured.searchParams.get('status'),'in.(missing,damaged,retired)');assert.equal(captured.searchParams.get('facility_id'),'eq.a');assert.equal(captured.searchParams.get('serial'),'ilike.%p86%');
});

test('all imported states count in Total without assigning unknown purposes to a category',()=>{
 const counts={available:482,vacant:556,overlock:16,auction:8,unclassified:43,tenant_held:5,missing:24,damaged:10,maintenance:2};
 assert.equal(categoryCount(counts,''),1146);assert.equal(categoryCount(counts,'unavailable'),34);
 for(const id of ['unclassified','tenant_held','maintenance','damaged'])assert.deepEqual(inventoryFilters.find(c=>c.id===id).statuses,[id]);
 assert.equal(inventoryCategories.length,6);
});

test('multi-facility employees can select only their authorized all-facility scope',()=>{
 assert.equal(readInventoryRoute('?facility=all','employee',facilities,'a').scope,'all');
 assert.equal(readInventoryRoute('','employee',facilities,'').scope,'all');
 assert.equal(readInventoryRoute('?facility=a','employee',facilities,'all').scope,'a');
 assert.equal(readInventoryRoute('?facility=unauthorized','employee',facilities,'a').scope,'all');
});
