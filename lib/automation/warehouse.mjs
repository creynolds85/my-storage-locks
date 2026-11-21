import {BigQuery} from '@google-cloud/bigquery';
import {createPrivateKey} from 'node:crypto';
export class WarehouseError extends Error{constructor(code){super(code);this.code=code}}
export function warehouseConfig(env){
 if(!env.CUBBY_BIGQUERY_SERVICE_ACCOUNT_JSON)throw new WarehouseError('warehouse_credentials_missing');
 let key;try{key=JSON.parse(env.CUBBY_BIGQUERY_SERVICE_ACCOUNT_JSON)}catch{throw new WarehouseError('warehouse_credentials_invalid')}
 if(key.type!=='service_account'||typeof key.client_email!=='string'||!/^[-a-zA-Z0-9_.]+@[-a-zA-Z0-9_.]+\.gserviceaccount\.com$/.test(key.client_email)||typeof key.private_key!=='string')throw new WarehouseError('warehouse_credentials_invalid');
 try{const parsed=createPrivateKey(key.private_key);if(parsed.asymmetricKeyType!=='rsa')throw Error()}catch{throw new WarehouseError('warehouse_credentials_invalid')}
 const project=env.CUBBY_BIGQUERY_PROJECT_ID||'cubby-partner-data',dataset=env.CUBBY_BIGQUERY_DATASET||'analytics',organization=env.CUBBY_ORGANIZATION_ID;
 if(!/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(project)||!/^[_a-zA-Z][_a-zA-Z0-9]{0,1023}$/.test(dataset)||!/^org_[a-zA-Z0-9]+$/.test(organization||''))throw new WarehouseError('warehouse_scope_invalid');
 // Ignore credential-supplied URLs and other authentication providers. This accepts only the expected Google service account.
 return {project,dataset,organization,credentials:{client_email:key.client_email,private_key:key.private_key,...(key.private_key_id?{private_key_id:key.private_key_id}:{})},location:env.CUBBY_BIGQUERY_LOCATION||undefined};
}
const TABLES=['door_locks','facilities','units','leases','payments','contacts'];
function safeError(error){if(error instanceof WarehouseError)return error;const code=Number(error?.code);return new WarehouseError(code===401?'warehouse_authentication_failed':code===403?'warehouse_permission_denied':code===404?'warehouse_dataset_or_table_missing':code===429?'warehouse_rate_limited':'warehouse_verification_failed')}
export async function verifyWarehouse(env,{clientFactory=options=>new BigQuery(options),now=()=>Date.now()}={}){
 const started=now();const config=warehouseConfig(env);const client=clientFactory({projectId:config.project,credentials:config.credentials,autoRetry:false,maxRetries:0});
 const base={useLegacySql:false,maximumBytesBilled:'104857600',jobTimeoutMs:25000,timeoutMs:25000,location:config.location,useQueryCache:false,labels:{app:'my_storage_locks',purpose:'warehouse_verify'}};
 async function read(query,params){try{return (await client.query({...base,query,params}))[0]}catch(error){throw safeError(error)}}
 const columns=await read(`SELECT table_name,column_name,data_type FROM \`${config.project}.${config.dataset}.INFORMATION_SCHEMA.COLUMNS\` WHERE table_name IN UNNEST(@tables)`,{tables:TABLES});
 if(!Array.isArray(columns)||columns.length>5000)throw new WarehouseError('warehouse_schema_incomplete');
 const byTable=Object.fromEntries(TABLES.map(name=>[name,columns.filter(c=>c.table_name===name).map(c=>c.column_name)]));
 const tables=TABLES.map(name=>({name,available:byTable[name].length>0,organizationScopeAvailable:byTable[name].includes('org_id')}));
 const result={state:'connected',project:config.project,dataset:config.dataset,verifiedAt:new Date(now()).toISOString(),tables,combinationColumnAvailable:byTable.door_locks.includes('combination'),publishedDefaultRefreshSeconds:null,measuredRefreshSeconds:null,actualSourceVisibilityLatencyVerified:false,eligibleForAutomaticCodeDisclosure:false,productionRecordsApplied:0};
 const required=['org_id','door_lock_id','facility_id','unit_id','serial_code','status','updated_at'];
 const missing=required.filter(c=>!byTable.door_locks.includes(c));
 if(missing.length){return {...result,state:'schema_review_required',missingLockColumns:missing,verificationDurationMs:now()-started}}
 // Every data query is explicitly scoped to the configured organization, even with provider-side row restrictions.
 const locks=`\`${config.project}.${config.dataset}.door_locks\``;
 const [summary]=await read(`SELECT COUNT(*) AS lock_count,COUNT(DISTINCT facility_id) AS lock_facilities,COUNTIF(door_lock_id IS NULL OR serial_code IS NULL) AS missing_identities,MAX(updated_at) AS newest_source_record_update FROM ${locks} WHERE org_id=@org`,{org:config.organization});
 const statuses=await read(`SELECT status,COUNT(*) AS count FROM ${locks} WHERE org_id=@org GROUP BY status ORDER BY status`,{org:config.organization});
 const duplicates=await read(`SELECT COUNT(*) AS duplicate_groups FROM (SELECT facility_id,LOWER(serial_code) AS serial FROM ${locks} WHERE org_id=@org GROUP BY facility_id,LOWER(serial_code) HAVING COUNT(*)>1)`,{org:config.organization});
 const value=x=>x&&typeof x==='object'&&'value' in x?x.value:x;
 return {...result,inventory:{locks:Number(value(summary?.lock_count)),facilitiesWithLocks:Number(value(summary?.lock_facilities)),missingIdentities:Number(value(summary?.missing_identities)),duplicateFacilitySerialGroups:Number(value(duplicates?.[0]?.duplicate_groups)),newestSourceRecordUpdate:value(summary?.newest_source_record_update)||null,statusCounts:Object.fromEntries(statuses.map(s=>[s.status,Number(value(s.count))]))},verificationDurationMs:now()-started,notice:'Source record update time is not proof of warehouse refresh or payment-clearance freshness. No combinations or tenant rows are returned.'};
}
// Targeted reconciliation probe, separate from polling and notification authorization.
export async function inspectWarehouseLockAssignments(env,facility,{clientFactory=options=>new BigQuery(options),now=()=>Date.now()}={}){
 if(!/^fac_[A-Za-z0-9]+$/.test(facility||''))throw new WarehouseError('warehouse_facility_invalid');
 const config=warehouseConfig(env),client=clientFactory({projectId:config.project,credentials:config.credentials,autoRetry:false,maxRetries:0});
 const query=`SELECT door_lock_id,serial_code,unit_id,status,CAST(updated_at AS STRING) AS source_updated_at FROM \`${config.project}.${config.dataset}.door_locks\` WHERE org_id=@org AND facility_id=@facility ORDER BY door_lock_id LIMIT 1001`;
 let rows;try{[rows]=await client.query({query,params:{org:config.organization,facility},useLegacySql:false,maximumBytesBilled:'104857600',jobTimeoutMs:20000,timeoutMs:20000,location:config.location,useQueryCache:false,labels:{app:'my_storage_locks',purpose:'lock_reconciliation'}})}catch(error){throw safeError(error)}
 if(!Array.isArray(rows)||rows.length>1000||new Set(rows.map(r=>r.door_lock_id)).size!==rows.length||rows.some(r=>!r.door_lock_id||!r.serial_code||!['ACTIVE','IN_TENANT','AVAILABLE','MISSING','DAMAGED'].includes(r.status)))throw new WarehouseError('warehouse_lock_identity_unverified');
 let metadataModifiedAt=null;try{const [meta]=await client.dataset(config.dataset).table('door_locks').getMetadata();metadataModifiedAt=meta.lastModifiedTime?new Date(Number(meta.lastModifiedTime)).toISOString():null}catch{}
 return {state:'connected',source:'bigquery',mode:'read_only',observedAt:new Date(now()).toISOString(),sourceFacilityId:facility,facilityLockCount:rows.length,metadataModifiedAt,metadataTimestampMeaning:'table_modified_not_source_event_visibility',inventoryWrites:0,combinationsReturned:false,records:rows.map(r=>({sourceLockId:r.door_lock_id,serial:r.serial_code,sourceUnitId:r.unit_id||null,status:r.status,sourceUpdatedAt:r.source_updated_at||null}))};
}

// Inspect available schemas without querying lock, combination, or tenant values.
export async function inspectWarehouseLockSources(env,{clientFactory=options=>new BigQuery(options)}={}){
 const cfg=warehouseConfig(env),client=clientFactory({projectId:cfg.project,credentials:cfg.credentials,autoRetry:false,maxRetries:0});
 const locations=new Map([[cfg.dataset,cfg.location]]);
 let datasetListComplete=false;
 try{
  const [datasets,next]=await client.getDatasets({maxResults:8,autoPaginate:false});
  datasetListComplete=!next;
  for(const d of datasets)if(typeof d.id==='string'&&/^[_a-zA-Z][_a-zA-Z0-9]{0,1023}$/.test(d.id)&&!locations.has(d.id))locations.set(d.id,d.metadata?.location||cfg.location);
 }catch{}
 const datasets=await Promise.all([...locations].map(async([name,location])=>{
  try{
   const [columns]=await client.query({query:`SELECT table_name,column_name,data_type FROM \`${cfg.project}.${name}.INFORMATION_SCHEMA.COLUMNS\`
    WHERE REGEXP_CONTAINS(LOWER(table_name), r'(lock|auction|^units$|^leases$|pipeline_run_log)')
    ORDER BY table_name,ordinal_position LIMIT 2001`,location,useLegacySql:false,maximumBytesBilled:'104857600',
    jobTimeoutMs:20000,timeoutMs:20000,useQueryCache:false,labels:{app:'my_storage_locks',purpose:'lock_schema_discovery'}});
   if(!Array.isArray(columns)||columns.length>2000)return {name,state:'schema_incomplete'};
   const tables={};
   for(const {table_name,column_name,data_type} of columns)(tables[table_name]??=[]).push({name:column_name,type:data_type});
   return {name,state:'verified',tables};
  }catch(error){return {name,state:safeError(error).code};}
 }));
 return {datasetListComplete,datasets,recordValuesReturned:false};
}
