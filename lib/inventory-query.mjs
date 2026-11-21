import {inventoryFilters} from './inventory-filters.mjs';
export function serialSearch(value){return String(value??'').replace(/[^a-zA-Z0-9]/g,'')}
export function effectiveInventorySort(sort,scope,facilityCount){
 if(sort!=='default'&&sort!=='default_desc')return sort;
 return inventorySortKey(scope==='all'&&facilityCount>1?'facility':'serial',inventorySortDirection(sort,'default'));
}
/**
 * @param {any} client
 * @param {{query?:string,scope?:string,filter?:string,sort?:string,limit?:number,offset?:number,signal?:AbortSignal}} options
 */
export async function fetchInventory(client,{query='',scope='all',filter='',sort='serial',limit=100,offset=0,signal}={}){
 const statuses=inventoryFilters.find(f=>f.id===filter)?.statuses||[];
 let request=client.rpc('inventory_listing',{p_query:query,p_facility:scope==='all'?null:scope,p_statuses:statuses.length?statuses:null,p_sort:sort,p_limit:limit,p_offset:offset});
 if(signal)request=request.abortSignal(signal);
 const {data,error}=await request;if(error)throw error;
 if(!data||!Array.isArray(data.items)||data.total===null||!Number.isFinite(Number(data.total)))throw Error('Inventory could not be loaded');
 return {items:data.items,total:Number(data.total)};
}

/** @param {any} client
 * @param {{query?:string,scope?:string,sort?:string,limit?:number,signal?:AbortSignal}} options
 */
export async function fetchDashboardMatches(client,{query='',scope='all',sort='serial',limit=20,signal}={}){
 let request=client.rpc('inventory_listing',{p_query:query,p_facility:scope==='all'?null:scope,p_statuses:null,p_sort:sort,p_limit:limit,p_offset:0,p_exact_count:false});
 if(signal)request=request.abortSignal(signal);
 const {data,error}=await request;if(error)throw error;
 if(!data||!Array.isArray(data.items))throw Error('Search could not be loaded');
 return {items:data.items,hasMore:data.hasMore===true};
}

export const inventorySortFields=[
 {field:'serial',label:'Serial Number'},
 {field:'color',label:'Physical Lock Color'},
 {field:'status',label:'Lock Status'},
 {field:'unit',label:'Unit Number'},
 {field:'facility',label:'Facility'},
];
export const inventorySortOptions=[
 {field:'default',label:'Default (Facility, then Serial)'},
 ...inventorySortFields,
];
export function inventorySortKey(field,direction){
 if(direction==='descending')return field+'_desc';
 if(field==='default'||field==='serial')return field;
 return field==='facility'?'facility_serial':field+'_asc';
}
export function inventorySortDirection(sort,field){
 if(sort===inventorySortKey(field,'descending'))return 'descending';
 if(sort===inventorySortKey(field,'ascending'))return 'ascending';
}
export function inventorySortOption(sort){
 return inventorySortOptions.find(option=>inventorySortDirection(sort,option.field))??inventorySortOptions[0];
}
export function toggleInventorySort(sort,field){
 return inventorySortKey(field,inventorySortDirection(sort,field)==='ascending'?'descending':'ascending');
}
