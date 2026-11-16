import {isConfirmed} from './walkthrough-progress.mjs';
export const QUICK_WALK_SIZE=1;
export const WALK_ROW_HEIGHT=96;
export const WALK_ROW_PITCH=104;
/** Filter without sorting: the persisted Cubby sequence is authoritative. */
export function walkRows(items,{mode='quick',query='',filter='all',leaving=new Set()}={}){
 const term=query.trim().toLowerCase();
 return items.filter(e=>(mode!=='quick'||!isConfirmed(e)||leaving.has(e.id))&&(!term||e.expected.label.toLowerCase().includes(term))&&(leaving.has(e.id)||filter==='all'||filter==='unchecked'&&!isConfirmed(e)||filter==='issues'&&!!e.issue||filter===e.expected.kind));
}
export function reviewWindow(count,scrollTop,height){const start=Math.max(0,Math.floor(scrollTop/WALK_ROW_PITCH)-3),end=Math.min(count,Math.ceil((scrollTop+height)/WALK_ROW_PITCH)+3);return {start:Math.min(start,count),end,top:Math.min(start,count)*WALK_ROW_PITCH,bottom:Math.max(0,count-end)*WALK_ROW_PITCH}}
// Acquire synchronously, before React renders disabled state or a queued save starts.
export function createConfirmationGate(){const active=new Set();return {run(id,task){if(active.has(id))return Promise.resolve(false);active.add(id);return Promise.resolve().then(task).finally(()=>active.delete(id))}}}

/** Next unconfirmed unit in the saved sequence; never returns the current unit. */
/** @param {Array<any>} items @param {string|null} [afterId] */
export function nextUncheckedUnit(items,afterId=null){const start=items.findIndex(e=>e.id===afterId);for(let n=1;n<=items.length;n++){const e=items[(start+n)%items.length];if(e.id!==afterId&&!isConfirmed(e))return e}return null}
export function activeQuickUnit(items,id){const current=items.find(e=>e.id===id&&!isConfirmed(e));return current||nextUncheckedUnit(items,id)}

/** Full List advancement never wraps, even when the confirmed row leaves a filter. */
/** @param {Array<any>} items @param {string|null} afterId @param {Set<string>|null} [visibleIds] */
export function nextForwardUncheckedUnit(items,afterId,visibleIds=null){const start=afterId===null?-1:items.findIndex(e=>e.id===afterId);if(afterId!==null&&start<0)return null;for(let i=start+1;i<items.length;i++){const entry=items[i];if(!isConfirmed(entry)&&(!visibleIds||visibleIds.has(entry.id)))return entry}return null}
