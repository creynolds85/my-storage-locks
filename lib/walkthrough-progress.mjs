export function isConfirmed(entry){return typeof entry.confirmed==='boolean'?entry.confirmed:entry.result==='confirmed'}
export function isInspected(entry){return isConfirmed(entry)||!!entry.issue}
export function inspectionProgress(items){const inspected=items.filter(isInspected).length;return {inspected,remaining:items.length-inspected,issues:items.filter(e=>!!e.issue).length}}
/** @param {Array<any>} items @param {string|null} [afterId] */
export function nextInspectionEntry(items,afterId=null){const start=items.findIndex(e=>e.id===afterId);for(let offset=1;offset<=items.length;offset++){const entry=items[(start+offset)%items.length];if(!isInspected(entry))return entry}return null}
export function patchInspectionEntry(page,entry){return {...page,completedAt:null,items:page.items.map(old=>old.id===entry.id?entry:old)}}
export function advanceBehavior(reducedMotion){return reducedMotion?'auto':'smooth'}
// Preserve explicit edits made during a save (for example notes blur followed by Confirm).
export function createInspectionQueue(){const tails=new Map();return {run(id,task){const job=(tails.get(id)||Promise.resolve()).catch(()=>{}).then(task);tails.set(id,job);void job.finally(()=>{if(tails.get(id)===job)tails.delete(id)}).catch(()=>{});return job}}}
