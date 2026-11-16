"use client";
import {useCallback,useEffect,useMemo,useRef,useState} from 'react';
import {ArrowRight,Check,ClipboardCheck,History,RefreshCw,Search,Undo2,X} from 'lucide-react';
import WalkthroughIssueDialog from '@/components/walkthrough-issue-dialog';
import WalkthroughFullList from '@/components/walkthrough-review-list';
import WalkthroughQuickUnit from '@/components/walkthrough-quick-unit';
import {walkRows,activeQuickUnit,nextUncheckedUnit,createConfirmationGate} from '@/lib/walkthrough-queue.mjs';
import {type WalkEntry} from '@/components/walkthrough-card';
import {createInspectionQueue,inspectionProgress,isConfirmed,patchInspectionEntry} from '@/lib/walkthrough-progress.mjs';
type Page={id:string;weekStart:string;completedAt:string|null;ordering:string;stale:boolean;historical:boolean;refreshedAt:string|null;sourceUnavailable?:boolean;items:WalkEntry[];policy:{vacantRequired:boolean|null;auctionLockType:string};history:{id:string;weekStart:string;completedAt:string|null}[]};
function dateLabel(value:string){return new Date(value+'T12:00:00').toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'})}
export default function Walkthrough({client,scope,admin,onAssign}:{client:any;scope:string;facilities:{id:string;name:string}[];admin:boolean;onAssign:(facility:string,unit:string,type:string)=>void}){
 const [mode,setMode]=useState<'quick'|'list'>('quick'),[quickId,setQuickId]=useState<string|null>(null),[issueId,setIssueId]=useState<string|null>(null);
 const [page,setPage]=useState<Page|null>(null),[selectedWeek,setSelectedWeek]=useState(''),[query,setQuery]=useState(''),[filter,setFilter]=useState('all'),[error,setError]=useState(''),[sourceError,setSourceError]=useState(''),[loading,setLoading]=useState(false),[pending,setPending]=useState<Set<string>>(new Set()),[policyBusy,setPolicyBusy]=useState(false),[historyOpen,setHistoryOpen]=useState(false),[focusId,setFocusId]=useState<string|null>(null),[feedback,setFeedback]=useState(''),[undo,setUndo]=useState<{id:string;label:string}|null>(null);
 const generation=useRef(0),active=useRef(new Set<string>()),pageRef=useRef<Page|null>(null),anchor=useRef<string|null>(null);
 const [queue]=useState(()=>createInspectionQueue()),[confirmationGate]=useState(()=>createConfirmationGate());
 const modeRef=useRef(mode),editingRef=useRef<string|null>(null),listPosition=useRef(0),listVisited=useRef(false),listOptions=useRef({mode:'list',query,filter});modeRef.current=mode;editingRef.current=issueId;listOptions.current={mode:'list',query,filter};
 const single=!!scope&&scope!=='all';
 const load=useCallback(async(refresh=false,interactive=false)=>{
 if(!single)return;const run=++generation.current;if(interactive)setLoading(true);
  try{
   if(refresh&&!selectedWeek){const {data:{session}}=await client.auth.getSession();const response=await fetch('/api/walkthrough/refresh',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+(session?.access_token||'')},body:JSON.stringify({facilityId:scope})});if(run!==generation.current)return;setSourceError(response.ok?'':'Current Cubby information could not be refreshed. Refresh before confirming units.');}
   const result=await client.rpc('walkthrough_page',{fid:scope,sid:selectedWeek||null});if(run!==generation.current)return;if(result.error)throw result.error;
   // Keep unchanged card objects stable during background refreshes.
   const prior=new Map(pageRef.current?.items.map(e=>[e.id,e]));const data=result.data as Page;
   data.items=data.items.map(e=>{const old=prior.get(e.id);return old&&old.version===e.version?old:e});pageRef.current=data;setPage(data);setQuickId(id=>activeQuickUnit(data.items,id)?.id||null);setError('');
  }catch{if(run===generation.current)setError('Unable to load this inspection. Please refresh and try again.');}
  finally{if(run===generation.current)setLoading(false)}
 },[client,scope,single,selectedWeek]);
 useEffect(()=>{pageRef.current=null;setPage(null);setQuery('');setFilter('all');setUndo(null);setFeedback('');anchor.current=null;setMode(selectedWeek?'list':'quick');setQuickId(null);setIssueId(null);listPosition.current=0;listVisited.current=!!selectedWeek;load(true,true);const timer=setInterval(()=>{if(!active.current.size&&!editingRef.current)load(true)},60000);return ()=>{generation.current++;clearInterval(timer)}},[load]);
 const advance=useCallback((entry:WalkEntry|null)=>{if(!entry)return;anchor.current=entry.id;setQuery('');setFilter('all');setFocusId(entry.id)},[]);
 const record=useCallback((id:string,mutation:Record<string,unknown>)=>{const originMode=modeRef.current;return queue.run(id,async()=>{
  const current=pageRef.current,entry=current?.items.find(e=>e.id===id);if(!current||!entry)return false;
  if(mutation.action==='set_confirmation'&&isConfirmed(entry)===mutation.confirmed)return true;
  if(mutation.action==='set_issue'&&entry.issue===mutation.issue)return true;
  if(mutation.action==='set_notes'&&entry.notes===mutation.notes)return true;
  ++generation.current;setLoading(false);active.current.add(id);setPending(new Set(active.current));setError('');
  try{
   const response=await client.rpc('walkthrough_record',{p:{weekId:current.id,entryId:id,version:entry.version,...mutation}});if(response.error||!response.data?.entry)throw Error('save_failed');
   if(pageRef.current?.id!==current.id)return false;const updated=response.data.entry as WalkEntry;const next=patchInspectionEntry(pageRef.current,updated) as Page;pageRef.current=next;setPage(next);
   if(mutation.action==='set_confirmation'){
    if(mutation.confirmed){
     setFeedback('Unit '+entry.expected.label+' confirmed');setUndo({id,label:entry.expected.label});
     setQuickId(current=>originMode==='quick'||current===id?nextUncheckedUnit(next.items,id)?.id||null:activeQuickUnit(next.items,current)?.id||null);
     if(originMode==='list'&&modeRef.current==='list')setFocusId(nextUncheckedUnit(walkRows(next.items,listOptions.current),id)?.id||null);
     if(originMode==='quick'&&modeRef.current==='quick')requestAnimationFrame(()=>document.querySelector<HTMLButtonElement>('.quick-confirm-button')?.focus({preventScroll:true}));
    }else{
     setFeedback('Confirmation undone for Unit '+entry.expected.label);setUndo(previous=>previous?.id===id?null:previous);
     if(originMode==='quick')setQuickId(id);else if(modeRef.current==='list')setFocusId(id);
    }
   }else setFeedback((mutation.action==='set_notes'?'Notes':'Issue')+' saved for Unit '+entry.expected.label);
   return true;
  }catch{if(pageRef.current?.id!==current.id)return false;await load(false);setError('Unable to save this unit. Review it and try again.');return false;}
  finally{active.current.delete(id);setPending(new Set(active.current))}
 })},[client,load,queue]);
 const confirm=useCallback((id:string,value:boolean)=>{void confirmationGate.run(id,()=>record(id,{action:'set_confirmation',confirmed:value}))},[record,confirmationGate]);
 const issue=useCallback((id:string,value:string|null)=>record(id,{action:'set_issue',issue:value}),[record]);
 const notes=useCallback((id:string,value:string)=>record(id,{action:'set_notes',notes:value}),[record]);
 const assign=useCallback((unit:string,type:string)=>onAssign(scope,unit,type),[onAssign,scope]);
 async function complete(){const current=pageRef.current;if(!current||active.current.size)return;try{const r=await client.rpc('walkthrough_record',{p:{weekId:current.id,action:'complete'}});if(r.error)throw r.error;const updated={...current,completedAt:r.data.completedAt};pageRef.current=updated;setPage(updated);setFeedback('Weekly inspection completed')}catch{setError('Refresh and inspect every current unit before completing.')}}
 async function policy(vacant:boolean|null,auction:string){setPolicyBusy(true);try{const r=await client.rpc('walkthrough_policy',{fid:scope,vacant_required:vacant,auction_lock_type:auction});if(r.error)throw r.error;await load(false,true)}catch{setError('Unable to save facility lock requirements. Please try again.')}finally{setPolicyBusy(false)}}
  const focused=useCallback(()=>setFocusId(null),[]);
 const closeIssue=useCallback(()=>{setIssueId(null);requestAnimationFrame(()=>{if(modeRef.current==='quick')document.querySelector<HTMLButtonElement>('.quick-confirm-button')?.focus({preventScroll:true})})},[]);
 const saveListPosition=useCallback((top:number)=>{listPosition.current=top},[]);
 const items=page?.items||[],progress=inspectionProgress(items),disabled=!!page?.historical||!!page?.stale||!!sourceError;
 const visible=useMemo(()=>walkRows(items,{mode:'list',query,filter}) as WalkEntry[],[items,query,filter]);
 const currentUnit=activeQuickUnit(items,quickId) as WalkEntry|null,nextUnit=currentUnit?nextUncheckedUnit(items,currentUnit.id) as WalkEntry|null:null,editing=items.find(e=>e.id===issueId),confirmedCount=items.filter(isConfirmed).length;
 const lastConfirmed=items.find(e=>e.id===undo?.id&&isConfirmed(e))||[...items.slice(0,currentUnit?items.findIndex(e=>e.id===currentUnit.id):items.length)].reverse().find(isConfirmed)||null;
 function changeMode(value:'quick'|'list'){if(value==='list'&&!listVisited.current){listVisited.current=true;setFocusId(currentUnit?.id||null)}if(value==='quick')setFocusId(null);setMode(value)}

 if(!single)return <section className="surface walkthrough-choose"><ClipboardCheck size={30}/><h2>Choose a facility to start walking</h2><p>Select a facility above to begin or resume its weekly inspection.</p></section>;
 return <section className={'walkthrough compact-walkthrough'+(mode==='quick'?' walkthrough-single':'')} aria-label="Weekly walk-through"><div className="surface walkthrough-summary"><div className="walk-header"><h2>{page?.weekStart?'Week of '+dateLabel(page.weekStart):'Weekly inspection'}</h2><div className="walk-header-actions"><button className="secondary" aria-label="Inspection history" aria-expanded={historyOpen} onClick={()=>setHistoryOpen(v=>!v)}><History size={16}/><span>History</span></button><button className="secondary" aria-label="Refresh walk-through" disabled={!!pending.size||loading} onClick={()=>load(true,true)}><RefreshCw size={16}/></button></div></div>
 {page&&!page.sourceUnavailable&&<><div className="walkthrough-progress" aria-label="Inspection progress"><span><strong>{progress.inspected}</strong> Inspected</span><span><strong>{progress.remaining}</strong> Remaining</span><span><strong>{progress.issues}</strong> Issues</span></div><progress max={items.length||1} value={progress.inspected} aria-label="Units inspected"/>
 {historyOpen&&<div className="walk-history-panel" aria-label="Previous inspections"><button className="secondary" onClick={()=>{setSelectedWeek('');setHistoryOpen(false)}}>Current week</button>{page.history.filter(h=>h.weekStart!==page.history[0]?.weekStart).map(h=><button className="secondary" key={h.id} onClick={()=>{setSelectedWeek(h.id);setHistoryOpen(false)}}>{dateLabel(h.weekStart)}{h.completedAt?' · Complete':''}</button>)}</div>}
 {page.historical&&<p className="walk-history-notice">Viewing a previous inspection. <button onClick={()=>setSelectedWeek('')}>Return to current week</button></p>}{page.completedAt&&<p className="walkthrough-complete"><Check size={15}/>Inspection complete</p>}
 {admin&&!selectedWeek&&<details className="walkthrough-policy"><summary>Facility lock requirements</summary><label>Vacant units<select aria-label="Vacant lock requirement" disabled={policyBusy} value={page.policy.vacantRequired===null?'unknown':String(page.policy.vacantRequired)} onChange={e=>policy(e.target.value==='unknown'?null:e.target.value==='true',page.policy.auctionLockType)}><option value="unknown">Not configured — no missing-lock assumption</option><option value="true">Facility lock required</option><option value="false">Facility lock not required</option></select></label><label>Auction security<select aria-label="Auction lock requirement" disabled={policyBusy} value={page.policy.auctionLockType} onChange={e=>policy(page.policy.vacantRequired,e.target.value)}><option value="auction">Auction lock</option><option value="overlock">Overlock</option><option value="none">No facility lock required</option></select></label></details>}</>}
 </div>
 {error&&<p className="operations-error" role="alert">{error}</p>}{(sourceError||page?.stale)&&!page?.historical&&<p className="operations-error" role="alert">{sourceError||'Cubby information is out of date. Refresh before confirming units.'}</p>}
 {page?.sourceUnavailable&&<p className="surface">Current unit information is unavailable. Use Refresh to try again.</p>}{!page&&loading&&<p role="status">Loading units…</p>}
 {!!items.length&&<><div className="walk-mode-bar"><div className="walk-mode-toggle" role="group" aria-label="Inspection mode"><button aria-pressed={mode==='quick'} onClick={()=>changeMode('quick')}>Quick Walk</button><button aria-pressed={mode==='list'} onClick={()=>changeMode('list')}>Full List</button></div>{mode==='list'&&<button className="secondary walk-next" disabled={!nextUncheckedUnit(items,anchor.current)} onClick={()=>advance(nextUncheckedUnit(items,anchor.current))}>Next Unchecked<ArrowRight size={17}/></button>}</div>
 {mode==='list'&&<div className="walkthrough-toolbar"><label className="search-input compact"><Search size={17}/><input aria-label="Search walk-through unit" placeholder="Find a unit…" value={query} onChange={e=>setQuery(e.target.value)}/></label><select aria-label="Filter walk-through" value={filter} onChange={e=>setFilter(e.target.value)}><option value="all">All units</option><option value="unchecked">Unchecked</option><option value="issues">Issues</option><option value="occupied">Occupied</option><option value="vacant">Vacant</option><option value="overlock">Overlocked</option><option value="auction">Auction</option></select></div>}
 {mode==='quick'?<WalkthroughQuickUnit entry={currentUnit} next={nextUnit} confirmed={confirmedCount} total={items.length} disabled={disabled} pending={!!currentUnit&&pending.has(currentUnit.id)} undoLabel={lastConfirmed?.expected.label||null} undoPending={!!lastConfirmed&&pending.has(lastConfirmed.id)} onConfirm={confirm} onIssue={setIssueId} onUndo={()=>{if(lastConfirmed)confirm(lastConfirmed.id,false)}} onAssign={assign}/>:<WalkthroughFullList items={visible} disabled={disabled} pending={pending} historical={!!page?.historical} focusId={focusId} onFocused={focused} onConfirm={confirm} onOpenIssue={setIssueId} onAssign={assign} initialScrollTop={listPosition.current} onPosition={saveListPosition}/>}

 {(mode==='list'||!currentUnit)&&<div className="walkthrough-finish"><button className="primary" disabled={disabled||!!pending.size||progress.remaining!==0||(mode==='quick'&&confirmedCount!==items.length)||!!page?.completedAt} onClick={complete}><ClipboardCheck size={18}/>{page?.completedAt?'Inspection complete':'Complete weekly inspection'}</button>{progress.remaining>0&&<small>Confirm or document an exception for every unit.</small>}</div>}</>}
 {editing&&<WalkthroughIssueDialog key={editing.id} entry={editing} disabled={disabled} pending={pending.has(editing.id)} onIssue={issue} onNotes={notes} onClose={closeIssue}/>}
 {feedback&&<div className="walkthrough-feedback" role="status"><span>{feedback}</span>{mode==='list'&&undo&&!page?.historical&&<button className="secondary" disabled={disabled||pending.has(undo.id)} onClick={()=>confirm(undo.id,false)}><Undo2 size={18}/>Undo Unit {undo.label}</button>}<button className="walk-feedback-close" aria-label="Dismiss feedback" onClick={()=>setFeedback('')}><X size={17}/></button></div>}
 </section>;
}
