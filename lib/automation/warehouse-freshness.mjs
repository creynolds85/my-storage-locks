import {randomUUID} from 'node:crypto';
import {BigQuery} from '@google-cloud/bigquery';
import {warehouseConfig,WarehouseError} from './warehouse.mjs';
const SPECS={
 facilities:{id:'facility_id',fields:['facility_id','name','time_zone'],markers:['updated_at','created_at']},
 leases:{id:'lease_id',fields:['lease_id','unit_id','facility_id','contact_id','is_active','is_lease_paid','is_needs_overlock','is_in_auction','is_access_code_enabled','balance_ar','documents_combined_status','lease_started','lease_ended'],markers:['updated_at','created_at']},
 payments:{id:'payment_id',fields:['payment_id','facility_id','contact_id','payment_status','payment_datetime','failed_at','payment_amount'],markers:['updated_at','payment_datetime','failed_at'],window:'payment_datetime'},
 units:{id:'unit_id',fields:['unit_id','facility_id','is_active','is_leased','is_rentable','is_overlocked','occupancy_state_since','rentability_state_since'],markers:['updated_at','occupancy_state_since','rentability_state_since','created_at']},
 contacts:{id:'contact_id',fields:['contact_id','phone','sms_comm_preference','sms_comm_updated_at','updated_at'],markers:['updated_at','sms_comm_updated_at','created_at']},
 book_entries:{id:'book_entry_id',fields:['book_entry_id','lease_id','contact_id','entry_date_time','book','ar_entry_category','type','amount'],markers:['updated_at','entry_date_time'],window:'entry_date_time'},
 cubby_events:{id:'cubby_event_id_int',fields:['cubby_event_id_int','type','created_at_utc','created_at'],markers:['created_at_utc','updated_at','created_at'],window:'created_at_utc'},
 unit_turnover:{id:'lease_id',fields:['lease_id','unit_id','activity_type','move_type','lease_started','lease_ended'],markers:['updated_at','created_at','activity_datetime','event_at']},
 lease_auctions:{id:'lease_id',fields:['lease_id','status','updated_at'],markers:['updated_at','created_at']},
};
const names=Object.keys(SPECS);
const timestampTypes=new Set(['TIMESTAMP','DATETIME']);
const unbox=x=>x&&typeof x==='object'&&'value' in x?x.value:x;
function safeCode(error){
 if(error instanceof WarehouseError)return error.code;
 if(Number(error?.code)===403)return 'warehouse_permission_denied';
 if(Number(error?.code)===404)return 'warehouse_dataset_or_table_missing';
 if(Number(error?.code)===429)return 'warehouse_rate_limited';
 if(Number(error?.code)===401)return 'warehouse_authentication_failed';
 if(/bytes billed|billing.*limit|bytes.*required/i.test(String(error?.message||''))||error?.errors?.some(e=>e.reason==='billingTierLimitExceeded'))return 'warehouse_query_budget_exceeded';
 return 'warehouse_probe_failed';
}
const col=name=>'`'+name+'`';
export async function inspectWarehouseFreshness(env,{clientFactory=o=>new BigQuery(o),now=()=>Date.now()}={}){
 const started=now(),config=warehouseConfig(env),client=clientFactory({projectId:config.project,credentials:config.credentials,autoRetry:false,maxRetries:0});
 const ref=name=>'`'+config.project+'.'+config.dataset+'.'+name+'`';
 const base={useLegacySql:false,maximumBytesBilled:'104857600',jobTimeoutMs:20000,timeoutMs:20000,location:config.location,useQueryCache:false,labels:{app:'my_storage_locks',purpose:'source_freshness'}};
 async function read(query,params={}){try{return (await client.query({...base,query,params}))[0]}catch(e){const safe=new WarehouseError(safeCode(e));safe.diagnostics={providerCode:Number(e?.code)||null,reason:['invalidQuery','billingTierLimitExceeded','accessDenied','rateLimitExceeded','resourcesExceeded'].includes(e?.errors?.[0]?.reason)?e.errors[0].reason:null,requiredBytes:Number(String(e?.message||'').match(/(\d+) or higher required/i)?.[1])||null};throw safe;}}
 const schema=await read(`SELECT table_name,column_name,data_type FROM ${ref('INFORMATION_SCHEMA.COLUMNS')} WHERE table_name IN UNNEST(@tables)`,{tables:[...names,'pipeline_run_log']});
 if(!Array.isArray(schema)||schema.length>4000)throw new WarehouseError('warehouse_schema_incomplete');
 const tableKinds=await read(`SELECT table_name,table_type FROM ${ref('INFORMATION_SCHEMA.TABLES')} WHERE table_name IN UNNEST(@tables)`,{tables:[...names,'pipeline_run_log']});
 const columns=name=>schema.filter(c=>c.table_name===name),kind=name=>tableKinds.find(t=>t.table_name===name)?.table_type||null;
 let pipeline=[];let pipelineError=null;
 const pipelineCols=columns('pipeline_run_log').map(c=>c.column_name);
 if(['model','last_success_build_at','as_of'].every(c=>pipelineCols.includes(c))){try{
  pipeline=await read(`SELECT model,CAST(as_of AS STRING) AS data_as_of,CAST(last_success_build_at AS STRING) AS successful_build_at${pipelineCols.includes('last_run_status')?',last_run_status':''} FROM ${ref('pipeline_run_log')} WHERE model IN UNNEST(@models) LIMIT 30`,{models:names});
 }catch(e){pipelineError=safeCode(e)}}
 const tables=[];
 // Bound concurrency and cost; do not fetch tenant values, event payloads, codes or payment details.
 for(let offset=0;offset<names.length;offset+=3){
  const group=await Promise.all(names.slice(offset,offset+3).map(async name=>{
   const spec=SPECS[name],cs=columns(name),types=Object.fromEntries(cs.map(c=>[c.column_name,c.data_type]));
   const entry={name,tableType:kind(name),available:cs.length>0,readable:false,organizationScoped:!!types.org_id,columns:cs.map(c=>({name:c.column_name,type:c.data_type})),markers:{},records:[],pipeline:pipeline.filter(p=>p.model===name)};
   if(!cs.length)return entry;
   if(!types.org_id)return {...entry,errorCode:'warehouse_organization_scope_missing'};
   const fields=spec.fields.filter(f=>types[f]&&!['JSON','STRUCT','RECORD','GEOGRAPHY','BYTES'].includes(types[f])),markers=spec.markers.filter(f=>timestampTypes.has(types[f]));
   const marker=markers[0];
   const window=types[spec.window]&&timestampTypes.has(types[spec.window])?spec.window:null;
   const where='org_id=@org'+(window?` AND ${col(window)}>=${types[window]==='DATETIME'?'DATETIME':'TIMESTAMP'}_SUB(CURRENT_${types[window]}(),INTERVAL 48 HOUR)`:'');
   try{
    const [row]=await read(`SELECT COUNT(*) AS row_count${markers.map(f=>`,CAST(MAX(${col(f)}) AS STRING) AS ${col('max_'+f)}`).join('')}${fields.length?`,CAST(BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(STRUCT(${fields.map(col).join(',')})))) AS STRING) AS state_fingerprint`:''} FROM ${ref(name)} WHERE ${where}`,{org:config.organization});
    entry.readable=true;entry.rowCount=Number(unbox(row?.row_count)||0);entry.stateFingerprint=unbox(row?.state_fingerprint)||null;entry.windowHours=window?48:null;
    entry.markers=Object.fromEntries(markers.map(f=>[f,{value:unbox(row?.['max_'+f])||null,type:types[f]}]));
    // Recent versions are hashed inside BigQuery. Historical baseline rows are not latency samples.
    if(marker&&types[spec.id]&&fields.length){
     const recent=await read(`SELECT TO_HEX(SHA256(CAST(${col(spec.id)} AS STRING))) AS record_hash,TO_HEX(SHA256(TO_JSON_STRING(STRUCT(${[...new Set([...fields,...markers])].map(col).join(',')})))) AS version_hash,CAST(${col(marker)} AS STRING) AS source_at FROM ${ref(name)} WHERE org_id=@org AND ${col(marker)}>=${types[marker]}_SUB(CURRENT_${types[marker]}(),INTERVAL 48 HOUR) ORDER BY ${col(marker)} DESC LIMIT 201`,{org:config.organization});
     entry.recordLimitReached=recent.length>200;
     entry.records=recent.slice(0,200).map(r=>({recordHash:r.record_hash,versionHash:r.version_hash,sourceAt:unbox(r.source_at),marker,utcVerified:types[marker]==='TIMESTAMP'||marker==='created_at_utc',latencyEligible:marker==='updated_at'||(name==='cubby_events'&&marker==='created_at_utc')}));
    }
   }catch(e){entry.errorCode=safeCode(e);entry.errorDiagnostics=e.diagnostics||null}
   try{
    const [meta]=await client.dataset(config.dataset).table(name).getMetadata();
    entry.metadataModifiedAt=meta.lastModifiedTime?new Date(Number(meta.lastModifiedTime)).toISOString():null;
    entry.metadataTimestampMeaning=entry.tableType==='VIEW'?'view_definition_modified_not_data_refresh':'table_modified_not_source_event_visibility';
   }catch(e){entry.metadataErrorCode=safeCode(e)}
   return entry;
  }));tables.push(...group);
 }
 let eventTypes=[];const ec=columns('cubby_events');
 if(ec.some(c=>c.column_name==='org_id')&&ec.some(c=>c.column_name==='type')&&ec.some(c=>c.column_name==='created_at_utc')){
  try{eventTypes=await read(`SELECT type,COUNT(*) AS count,CAST(MAX(created_at_utc) AS STRING) AS newest_event_at FROM ${ref('cubby_events')} WHERE org_id=@org AND created_at_utc>=${ec.find(c=>c.column_name==='created_at_utc').data_type}_SUB(CURRENT_${ec.find(c=>c.column_name==='created_at_utc').data_type}(),INTERVAL 48 HOUR) AND REGEXP_CONTAINS(type,r'OVERLOCK|PAYMENT|MOVE_IN|MOVE_OUT|LEASE_CREATED|DOCUMENT|ACCESS') GROUP BY type ORDER BY newest_event_at DESC LIMIT 40`,{org:config.organization})}catch(e){pipelineError=pipelineError||safeCode(e)}
 }
 return {state:'connected',project:config.project,dataset:config.dataset,observedAt:new Date(now()).toISOString(),startedAt:new Date(started).toISOString(),durationMs:now()-started,tables,pipelineAvailable:pipeline.length>0,pipelineErrorCode:pipelineError,eventTypes,sourceTimestampTimezoneVerified:false,eligibleForAutomaticCodeDisclosure:false,productionInventoryWrites:0};
}
export async function observeWarehouse(rt){
 if(!rt.env.CUBBY_BIGQUERY_SERVICE_ACCOUNT_JSON)return {state:'not_configured'};
 const owner=randomUUID();const claim=await rt.store.call('warehouse_claim',{owner});if(!claim)return {state:'already_sampled_or_running'};
 try{
  const observation=await inspectWarehouseFreshness(rt.env,rt.warehouseOptions||{});
  await rt.store.call('warehouse_finish',{owner,observation});return {state:observation.state,readableTables:observation.tables.filter(t=>t.readable).map(t=>t.name),eligibleForAutomaticCodeDisclosure:false};
 }catch(e){await rt.store.call('warehouse_finish',{owner,errorCode:safeCode(e)});return {state:'failed',errorCode:safeCode(e)}}
}
