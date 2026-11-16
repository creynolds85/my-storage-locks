import {isInspected} from './walkthrough-progress.mjs';
export const QUICK_WALK_SIZE=10;
export const WALK_ROW_HEIGHT=80;
export const WALK_ROW_PITCH=88;
/** Filter without sorting: the persisted Cubby sequence is authoritative. */
export function walkRows(items,{mode='quick',query='',filter='all',leaving=new Set()}={}){
 const term=query.trim().toLowerCase();
 return items.filter(e=>(mode!=='quick'||!isInspected(e)||leaving.has(e.id))&&(!term||e.expected.label.toLowerCase().includes(term))&&(leaving.has(e.id)||filter==='all'||filter==='unchecked'&&!isInspected(e)||filter==='issues'&&!!e.issue||filter===e.expected.kind));
}
export function reviewWindow(count,scrollTop,height){const start=Math.max(0,Math.floor(scrollTop/WALK_ROW_PITCH)-3),end=Math.min(count,Math.ceil((scrollTop+height)/WALK_ROW_PITCH)+3);return {start:Math.min(start,count),end,top:Math.min(start,count)*WALK_ROW_PITCH,bottom:Math.max(0,count-end)*WALK_ROW_PITCH}}
// Acquire synchronously, before React renders disabled state or a queued save starts.
export function createConfirmationGate(){const active=new Set();return {run(id,task){if(active.has(id))return Promise.resolve(false);active.add(id);return Promise.resolve().then(task).finally(()=>active.delete(id))}}}
