import test from 'node:test';import assert from 'node:assert/strict';import {generateKeyPairSync} from 'node:crypto';
import {readLockSnapshot,validateLockSnapshot,runLockMirror} from '../lib/automation/lock-mirror.mjs';
const {privateKey}=generateKeyPairSync('rsa',{modulusLength:2048,privateKeyEncoding:{type:'pkcs8',format:'pem'},publicKeyEncoding:{type:'spki',format:'pem'}});
const env={CUBBY_BIGQUERY_SERVICE_ACCOUNT_JSON:JSON.stringify({type:'service_account',client_email:'fixture@fixture.iam.gserviceaccount.com',private_key:privateKey}),CUBBY_ORGANIZATION_ID:'org_fixture'};
const now=Date.parse('2026-11-16T04:00:00Z');
const row={sourceLockId:'lock_fixture',serial:'000A1',facilityId:'fac_fixture',unitId:null,unit:null,unitMatches:0,status:'AVAILABLE',combination:'00-A 01',updatedAt:'2026-11-15 20:00:00',total_rows:1};
function options({age=1000,changing=false,updatedType='DATETIME',comboType='STRING',colorColumn=null,colorValue=null}={}){let reads=0;const queries=[];return {queries,now:()=>now,clientFactory:()=>({dataset:()=>({table:()=>({getMetadata:async()=>[{type:'TABLE',lastModifiedTime:String(now-age+(changing?reads++:0))}]})}),query:async q=>{queries.push(q);if(q.query.includes('INFORMATION_SCHEMA'))return [[...['org_id','door_lock_id','serial_code','facility_id','unit_id','status',...(comboType?['combination']:[]),...(colorColumn?[colorColumn]:[])].map(column_name=>({table_name:'door_locks',column_name,data_type:'STRING'})),{table_name:'door_locks',column_name:'updated_at',data_type:updatedType},...['org_id','unit_id','facility_id','unit_name'].map(column_name=>({table_name:'units',column_name,data_type:'STRING'}))]];return [[{...row,...(!comboType?{combination:null,combinationAvailable:false}:{}),...(colorColumn==='physical_color'||colorColumn==='lock_color'?{physicalColor:colorValue}:{})}]]}})}}
test('source read preserves exact serial/combination strings, scopes every record query, and never invents purpose',async()=>{const o=options();const s=await readLockSnapshot(env,o);assert.equal(s.records[0].combination,'00-A 01');assert.equal(s.records[0].serial,'000A1');assert.equal(s.capabilities.explicitPurpose,false);assert.equal(o.queries[1].params.org,'org_fixture');assert.ok(o.queries[1].query.includes('WHERE d.org_id=@org'));assert.ok(!JSON.stringify(o.queries).includes('00-A 01'));});
test('unchanged watermark skips full lock download',async()=>{const first=await readLockSnapshot(env,options());const o=options();const r=await readLockSnapshot(env,{...o,previousKey:first.key});assert.equal(r.unchanged,true);assert.equal(o.queries.length,1);});
test('stale, changing, duplicate and incomplete snapshots fail closed',async()=>{await assert.rejects(()=>readLockSnapshot(env,options({age:96*60000})),/lock_source_stale/);await assert.rejects(()=>readLockSnapshot(env,options({changing:true})),/lock_snapshot_changed/);assert.throws(()=>validateLockSnapshot([{...row,total_rows:2}]),/incomplete/);assert.throws(()=>validateLockSnapshot([{...row,total_rows:2},{...row,total_rows:2}]),/ambiguous/);});
test('disabled or future-authority mode performs no warehouse reads',async()=>{let read=false;assert.deepEqual(await runLockMirror({store:{call:async()=>null}},{reader:async()=>{read=true}}),{state:'not_due_or_disabled'});assert.equal(read,false);});
test('mirror sends bounded sensitive batches only to the existing store and returns no combinations',async()=>{const calls=[];const rt={env,store:{call:async(op,p)=>{calls.push(op);if(op==='lock_mirror_claim')return {};if(op==='lock_mirror_start')return {id:'fixture'};if(op==='lock_mirror_batch'){assert.equal(p.records[0].combination,'00-A 01');return {saved:true}}if(op==='lock_mirror_finish')return {mode:'mirror',matched:1}}}};const r=await runLockMirror(rt,{reader:async()=>({records:validateLockSnapshot([row]),orgId:'org_fixture',snapshotAt:'2026-11-16T04:00:00Z',key:'fixture',capabilities:{}})});assert.equal(r.matched,1);assert.ok(!JSON.stringify(r).includes('00-A'));assert.deepEqual(calls,['lock_mirror_claim','lock_mirror_start','lock_mirror_batch','lock_mirror_finish']);});
test('provider errors and rejected batches produce only fixed safe diagnostics',async()=>{const calls=[];const rt={env,store:{call:async op=>{calls.push(op);return op==='lock_mirror_claim'?{}:null}}};const r=await runLockMirror(rt,{reader:async()=>{throw Error('PRIVATE_PAYLOAD')}});assert.equal(r.code,'lock_mirror_processing_failed');assert.ok(!JSON.stringify(r).includes('PRIVATE'));assert.ok(calls.includes('lock_mirror_fail'));});

test('serialized source update timestamps require a concrete timestamp and never relative dates',async()=>{const s=await readLockSnapshot(env,options({updatedType:'STRING'}));assert.equal(s.records[0].updatedAt,'2026-11-15 20:00:00');assert.equal(s.capabilities.updatedAtType,'STRING');assert.equal(validateLockSnapshot([{...row,updatedAt:'now'}])[0].updatedAt,null);});

test('missing combination column still permits verified metadata reads without inventing values',async()=>{const o=options({comboType:null});const s=await readLockSnapshot(env,o);assert.equal(s.capabilities.combinations,false);assert.equal(s.records[0].combination,null);assert.equal(s.records[0].combinationAvailable,false);assert.ok(o.queries[1].query.includes('CAST(NULL AS STRING) AS combination'));});

test('only dedicated verified physical color fields emit a supported color',async()=>{
 const dedicated=options({colorColumn:'physical_color',colorValue:' gReEn '});
 const s=await readLockSnapshot(env,dedicated);
 assert.equal(s.records[0].physicalColor,'Green');
 assert.equal(s.capabilities.physicalLockColorColumn,'physical_color');
 assert.match(dedicated.queries[1].query,/d\.physical_color AS physicalColor/);
 const generic=options({colorColumn:'color',colorValue:'Red'});
 const g=await readLockSnapshot(env,generic);
 assert.equal(g.capabilities.physicalLockColorColumn,null);
 assert.equal(g.records[0].physicalColor,undefined);
 assert.match(generic.queries[1].query,/CAST\(NULL AS STRING\) AS physicalColor/);
 for(const physicalColor of ['Unknown','ACTIVE','vacant',null]){
  assert.equal(validateLockSnapshot([{...row,physicalColor}])[0].physicalColor,undefined);
 }
});
