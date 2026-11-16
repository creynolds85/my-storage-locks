import {BigQuery} from '@google-cloud/bigquery';
import {randomUUID} from 'node:crypto';
import {warehouseConfig,WarehouseError} from './warehouse.mjs';
const MAX=10000;
const scalar=v=>v&&typeof v==='object'&&'value' in v?v.value:v;
const sourceMarker=v=>{const x=scalar(v);return typeof x==='string'&&/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z| UTC|[+-]\d{2}(?::?\d{2})?)?$/.test(x)?x:null};
export function validateLockSnapshot(rows){
 if(!Array.isArray(rows)||!rows.length||rows.length>MAX||Number(rows[0].total_rows)!==rows.length)throw new WarehouseError('lock_snapshot_incomplete');
 if(new Set(rows.map(r=>r.sourceLockId)).size!==rows.length)throw new WarehouseError('lock_identity_ambiguous');
 return rows.map(r=>({sourceLockId:r.sourceLockId,serial:r.serial,facilityId:r.facilityId||null,unitId:r.unitId||null,unit:r.unit||null,unitMatches:Number(r.unitMatches),status:r.status,updatedAt:sourceMarker(r.updatedAt),createdAt:sourceMarker(r.createdAt),combination:r.combination,needsMaintenance:r.needsMaintenance,customLocation:r.customLocation||null}));
}
export async function readLockSnapshot(env,{previousKey=null,clientFactory=o=>new BigQuery(o),now=()=>Date.now()}={}){
 const cfg=warehouseConfig(env),client=clientFactory({projectId:cfg.project,credentials:cfg.credentials,autoRetry:false,maxRetries:0});
 const ref=t=>'`'+cfg.project+'.'+cfg.dataset+'.'+t+'`';
 const base={useLegacySql:false,maximumBytesBilled:'167772160',jobTimeoutMs:20000,timeoutMs:20000,location:cfg.location,useQueryCache:false,labels:{app:'my_storage_locks',purpose:'lock_mirror'}};
 const read=async(query,params={})=>{try{return (await client.query({...base,query,params}))[0]}catch{throw new WarehouseError('lock_source_read_failed')}};
 const schema=await read(`SELECT table_name,column_name,data_type FROM ${ref('INFORMATION_SCHEMA.COLUMNS')} WHERE table_name IN ('door_locks','units','pipeline_run_log')`);
 const col=(t,n)=>schema.find(s=>s.table_name===t&&s.column_name===n)?.data_type;
 for(const n of ['org_id','door_lock_id','serial_code','facility_id','unit_id','status'])if(col('door_locks',n)!=='STRING')throw new WarehouseError('lock_source_schema_unverified');
 if(col('door_locks','combination')!=='STRING'||!['TIMESTAMP','DATETIME','STRING'].includes(col('door_locks','updated_at'))){const error=new WarehouseError('lock_combination_or_version_unverified');error.sourceSchema={combination:col('door_locks','combination')||'missing',updatedAt:col('door_locks','updated_at')||'missing'};throw error;}
 for(const n of ['org_id','unit_id','facility_id','unit_name'])if(col('units',n)!=='STRING')throw new WarehouseError('lock_unit_schema_unverified');
 async function watermark(){
  const metadata=await Promise.all(['door_locks','units'].map(async t=>{try{const [m]=await client.dataset(cfg.dataset).table(t).getMetadata();return {table:t,type:m.type,modified:Number(m.lastModifiedTime)}}catch{throw new WarehouseError('lock_source_watermark_unavailable')}}));
  let times=metadata.map(m=>m.type==='TABLE'&&Number.isFinite(m.modified)?m.modified:null),basis='table_modified';
  if(times.some(t=>t===null)){
   if(col('pipeline_run_log','model')!=='STRING'||col('pipeline_run_log','as_of')!=='TIMESTAMP')throw new WarehouseError('lock_source_refresh_unverified');
   const pipeline=await read(`SELECT model,CAST(as_of AS STRING) AS as_of FROM ${ref('pipeline_run_log')} WHERE model IN ('door_locks','units') LIMIT 10`);
   times=['door_locks','units'].map(t=>{const matches=pipeline.filter(p=>p.model===t);return matches.length===1?Date.parse(scalar(matches[0].as_of)):null});basis='pipeline_as_of';
  }
  if(times.some(t=>!Number.isFinite(t))||Math.min(...times)<now()-95*60000||Math.max(...times)>now()+30000)throw new WarehouseError('lock_source_stale');
  return {key:JSON.stringify({basis,times}),snapshotAt:new Date(Math.min(...times)).toISOString(),basis};
 }
 const before=await watermark();
 const capabilities={immutableIds:true,serials:true,combinations:true,unitAssignments:true,broadStatus:true,explicitPurpose:false,assignmentEventHistory:false,deletionsVerified:false,updatedAtType:col('door_locks','updated_at'),snapshotBasis:before.basis};
 if(previousKey===before.key)return {...before,orgId:cfg.organization,unchanged:true,capabilities};
 const optional=(n,type)=>col('door_locks',n)===type?'d.'+n:'NULL';
 // One atomic, organization-scoped query. No combination values appear in SQL text, labels or logs.
 const rows=await read(`WITH scoped_units AS (SELECT unit_id,facility_id,ANY_VALUE(unit_name) AS unit_name,COUNT(*) AS n FROM ${ref('units')} WHERE org_id=@org GROUP BY unit_id,facility_id)
 SELECT d.door_lock_id AS sourceLockId,d.serial_code AS serial,d.facility_id AS facilityId,d.unit_id AS unitId,u.unit_name AS unit,COALESCE(u.n,0) AS unitMatches,d.status,d.combination,CAST(d.updated_at AS STRING) AS updatedAt,${['TIMESTAMP','DATETIME'].includes(col('door_locks','created_at'))?'CAST(d.created_at AS STRING)':'NULL'} AS createdAt,${optional('needs_maintenance','BOOL')} AS needsMaintenance,${optional('custom_location','STRING')} AS customLocation,COUNT(*) OVER() AS total_rows
 FROM ${ref('door_locks')} d LEFT JOIN scoped_units u ON u.unit_id=d.unit_id AND u.facility_id=d.facility_id WHERE d.org_id=@org ORDER BY d.door_lock_id LIMIT 10001`,{org:cfg.organization});
 const records=validateLockSnapshot(rows),after=await watermark();
 if(before.key!==after.key)throw new WarehouseError('lock_snapshot_changed_during_read');
 // Unknown or malformed individual records are isolated by the database; independent valid rows can still synchronize.
 return {...before,orgId:cfg.organization,capabilities,records};
}
export async function runLockMirror(rt,{reader=readLockSnapshot,force=false}={}){
 const owner=randomUUID();let claim;
 try{
  claim=await rt.store.call('lock_mirror_claim',{owner,force});
  if(!claim)return {state:'not_due_or_disabled'};
  const snapshot=await reader(rt.env,{previousKey:force?null:claim.snapshotKey,...rt.lockMirrorOptions});
  if(snapshot.unchanged){return await rt.store.call('lock_mirror_unchanged',{owner,snapshotAt:snapshot.snapshotAt,key:snapshot.key})}
  const run=await rt.store.call('lock_mirror_start',{owner,orgId:snapshot.orgId,snapshotAt:snapshot.snapshotAt,key:snapshot.key,total:snapshot.records.length,capabilities:snapshot.capabilities});
  if(!run?.id)throw new WarehouseError('lock_mirror_run_rejected');
  for(let offset=0;offset<snapshot.records.length;offset+=60){const saved=await rt.store.call('lock_mirror_batch',{owner,runId:run.id,records:snapshot.records.slice(offset,offset+60)});if(saved?.saved!==true)throw new WarehouseError('lock_mirror_batch_rejected');}
  const result=await rt.store.call('lock_mirror_finish',{owner,runId:run.id});if(result?.mode!=='mirror')throw new WarehouseError('lock_mirror_finish_rejected');return result;
 }catch(error){
  const code=error instanceof WarehouseError?error.code:'lock_mirror_processing_failed';
  if(claim)try{await rt.store.call('lock_mirror_fail',{owner,errorCode:code})}catch{}
  return {state:'failed',code};
 }
}
