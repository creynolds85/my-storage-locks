import test from 'node:test';
import assert from 'node:assert/strict';
import {combinationProblem,employeeError} from '../lib/lock-edit.mjs';
import {inventoryCategories,inventoryFilters,categoryCount,readInventoryRoute} from '../lib/inventory-filters.mjs';
test('Other partitions all supported statuses and preserves its facility/filter route',()=>{
 const counts={available:482,vacant:556,overlock:16,auction:8,unclassified:43,tenant_held:5,missing:24,damaged:10,maintenance:2,retired:0};
 assert.equal(categoryCount(counts,'other'),50);
 assert.equal(inventoryCategories.slice(1).reduce((n,c)=>n+categoryCount(counts,c.id),0),categoryCount(counts,''));
 assert.equal(new Set(inventoryCategories.slice(1).flatMap(c=>c.statuses)).size,Object.keys(counts).length);
 assert.deepEqual(inventoryCategories.at(-1),{id:'other',label:'Other',color:'#7C3AED',statuses:['unclassified','tenant_held','maintenance']});
 for(const status of ['unclassified','tenant_held','maintenance'])assert.deepEqual(inventoryFilters.find(c=>c.id===status).statuses,[status]);
 assert.deepEqual(readInventoryRoute('?view=inventory&status=other&facility=a','employee',[{id:'a'}],'a'),{view:'inventory',scope:'a',filter:'other'});
 assert.equal(readInventoryRoute('?view=activity','admin',[{id:'a'}],'a').view,'dashboard');
});
test('new combinations require exact confirmation and physical verification without normalization',()=>{
 for(const value of ['0012','00-03-X',' 001 A--z '])assert.equal(combinationProblem(value,value,true),'');
 for(const [a,b,verified] of [['','',true],['0012','012',true],[' 0012','0012',true],['a','A',true],['0012','0012',false],['x'.repeat(201),'x'.repeat(201),true]])assert.notEqual(combinationProblem(a,b,verified),'');
});
test('employee errors do not echo raw backend messages or sensitive request data',()=>{
 const raw='RPC transaction 481 secret=TEST-ONLY';
 assert.ok(!employeeError({message:raw}).includes(raw));
 assert.match(employeeError({code:'40001',message:raw}),/reopen/);
 assert.match(employeeError({code:'55P03',message:raw}),/access message/);
});
