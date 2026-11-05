import {inventoryFilters} from './inventory-filters.mjs';
export function serialSearch(value){return String(value??'').replace(/[^a-zA-Z0-9]/g,'')}
export function effectiveInventorySort(sort,scope,facilityCount){
 return sort==='default'?(scope==='all'&&facilityCount>1?'facility_serial':'serial'):sort;
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
