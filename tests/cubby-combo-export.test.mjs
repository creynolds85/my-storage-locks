import test from 'node:test';
import assert from 'node:assert/strict';
import {parseCubbyComboExport} from '../lib/cubby-combo-export.mjs';
import {prepareCubbyExportEnvelope,sealCubbyExport,openCubbyExport} from '../lib/automation/cubby-export-envelope.mjs';
import {physicalColors,recordedPhysicalColor,validateImport} from '../lib/csv.mjs';
import {inventorySortFields,inventorySortDirection,toggleInventorySort} from '../lib/inventory-query.mjs';

test('official exports preserve literal combinations and unit identifiers and discard staff fields',()=>{
 const header='Serial code,Combination,Status,Facility,Unit Number,Updated By\n';
 const result=parseCubbyComboExport(header+"TEST1,0009,On vacant unit,Fixture,004,Staff\nTEST2,00-A 0,Available,Fixture,'-,Staff\n");
 assert.deepEqual(result.records,[
  {serial:'TEST1',unit:'004',label:'On vacant unit',combination:'0009'},
  {serial:'TEST2',unit:null,label:'Available',combination:'00-A 0'},
 ]);
 assert.throws(()=>parseCubbyComboExport(header+'TEST1,001,Available,Fixture,-,Staff\nTEST1,002,Available,Fixture,-,Staff'));
 assert.throws(()=>parseCubbyComboExport(header+'TEST1,001,Available,Fixture,-,Staff\nTEST2,002,Available,Other Facility,-,Staff'));
});

test('worker export envelope stays encrypted and expires',()=>{
 const now=123456789,secret='fixture-only-secret';
 const payload={records:[{combination:'fixture-synthetic-value'}]};
 const key=prepareCubbyExportEnvelope(secret,now);
 const envelope=sealCubbyExport(key,payload);
 assert.ok(!JSON.stringify(envelope).includes(payload.records[0].combination));
 assert.deepEqual(openCubbyExport(secret,envelope,now),payload);
 assert.throws(()=>openCubbyExport(secret,envelope,key.expires+1),/expired/);
 assert.throws(()=>openCubbyExport('wrong-fixture-key',envelope,now));
});

test('only the four physical colors are accepted and blank historical data stays unset',()=>{
 assert.deepEqual(physicalColors,['Green','Red','Blue','Black']);
 assert.equal(recordedPhysicalColor('Unknown'),null);
 const facilities=[{id:'facility',identifier:'facility',active:true}];
 function row(color){return {serial:'TEST1',combination:'fixture',facility:'facility',color};}
 for(const color of physicalColors)assert.equal(validateImport([row(color)],facilities).valid[0].color,color);
 for(const color of ['Unknown','Other','Purple'])assert.ok(validateImport([row(color)],facilities).errors.length);
 assert.ok(!Object.hasOwn(validateImport([row('')],facilities).valid[0],'color'));
});

test('each inventory field alternates asc/desc and retains the existing default sort keys',()=>{
 assert.deepEqual(inventorySortFields.map(({field})=>field),['serial','color','status','unit','facility']);
 for(const {field} of inventorySortFields){
  const ascending=toggleInventorySort('',field),descending=toggleInventorySort(ascending,field);
  assert.equal(inventorySortDirection(ascending,field),'ascending');
  assert.equal(inventorySortDirection(descending,field),'descending');
  assert.equal(toggleInventorySort(descending,field),ascending);
 }
});
