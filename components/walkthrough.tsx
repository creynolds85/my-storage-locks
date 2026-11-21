"use client";
import {useCallback,useEffect,useLayoutEffect,useMemo,useRef,useState} from 'react';
import {ArrowRight,Check,ClipboardCheck,History,Plus,RefreshCw,Search,Undo2,X} from 'lucide-react';
import WalkthroughHistory,{inspectionTime,type InspectionSummary} from '@/components/walkthrough-history';
import {quickWalkHeight} from '@/lib/walkthrough-viewport.mjs';
import WalkthroughIssueDialog from '@/components/walkthrough-issue-dialog';
import WalkthroughFullList,{type WalkScrollRequest} from '@/components/walkthrough-review-list';
import WalkthroughQuickUnit from '@/components/walkthrough-quick-unit';
import {walkRows,activeQuickUnit,nextUncheckedUnit,nextForwardUncheckedUnit,createConfirmationGate} from '@/lib/walkthrough-queue.mjs';
import {type WalkEntry} from '@/components/walkthrough-card';
import {createInspectionQueue,inspectionProgress,isConfirmed,patchInspectionEntry} from '@/lib/walkthrough-progress.mjs';
type Page=InspectionSummary&{ordering:string;stale:boolean;historical:boolean;refreshedAt:string|null;sourceUnavailable?:boolean;items:WalkEntry[];policy:{vacantRequired:boolean|null;auctionLockType:string};history:InspectionSummary[]};
export default function Walkthrough({client,scope,admin,onAssign}:{client:any;scope:string;facilities:{id:string;name:string}[];admin:boolean;onAssign:(facility:string,unit:string,type:string)=>void}){
 const [mode,setMode]=useState<'quick'|'list'>('quick'),[quickId,setQuickId]=useState<string|null>(null),[issueId,setIssueId]=useState<string|null>(null),[celebrating,setCelebrating]=useState<Set<string>>(new Set()),[quickSuccess,setQuickSuccess]=useState<string|null>(null),[sessionBusy,setSessionBusy]=useState(false);
 const [page,setPage]=useState<Page|null>(null),[selectedWeek,setSelectedWeek]=useState(''),[query,setQuery]=useState(''),[filter,setFilter]=useState('all'),[error,setError]=useState(''),[sourceError,setSourceError]=useState(''),[loading,setLoading]=useState(false),[pending,setPending]=useState<Set<string>>(new Set()),[policyBusy,setPolicyBusy]=useState(false),[historyOpen,setHistoryOpen]=useState(false),[scrollRequest,setScrollRequest]=useState<WalkScrollRequest|null>(null),[feedback,setFeedback]=useState(''),[undo,setUndo]=useState<{id:string;label:string}|null>(null);
 const [confirming,setConfirming]=useState<Set<string>>(new Set());
 const section=useRef<HTMLElement>(null),newRequest=useRef<string|null>(null),managementBusy=useRef(false),confirmationTimers=useRef(new Map<string,ReturnType<typeof setTimeout>>()),quickSuccessRef=useRef<string|null>(null);
 const generation=useRef(0),active=useRef(new Set<string>()),pageRef=useRef<Page|null>(null),anchor=useRef<string|null>(null);
 const [queue]=useState(()=>createInspectionQueue()),[confirmationGate]=useState(()=>createConfirmationGate());
 const modeRef=useRef(mode),editingRef=useRef<string|null>(null),listPosition=useRef(0),listVisited=useRef(false),listNavigation=useRef(0),listOptions=useRef({mode:'list',query,filter});modeRef.current=mode;editingRef.current=issueId||(historyOpen?'history':null);listOptions.current={mode:'list',query,filter};
 const single=!!scope&&scope!=='all';
 const refreshSource=useCallback(async()=>{const {data:{session}}=await client.auth.getSession();const response=await fetch('/api/walkthrough/refresh',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+(session?.access_token||'')},body:JSON.stringify({facilityId:scope})});if(!response.ok)throw Error('source_refresh_failed')},[client,scope]);
 const load=useCallback(async(refresh=false,interactive=false)=>{
 if(!single)return;const run=++generation.current;if(interactive)setLoading(true);
  try{
   if(refresh){try{await refreshSource();setSourceError('')}catch{setSourceError('Current Cubby information could not be refreshed. Refresh before confirming units.')}if(run!==generation.current)return;}
   const result=await client.rpc('walkthrough_page',{fid:scope,sid:selectedWeek||null});if(run!==generation.current)return;if(result.error)throw result.error;
   // Keep unchanged card objects stable during background refreshes.
   const prior=new Map(pageRef.current?.items.map(e=>[e.id,e]));const data=result.data as Page;
   data.items=data.items.map(e=>{const old=prior.get(e.id);return old&&pageRef.current?.id===data.id&&old.version===e.version&&old.expected.sourceReview===e.expected.sourceReview&&old.expected.assignmentReview===e.expected.assignmentReview&&old.expected.missing===e.expected.missing&&old.expected.mirrorMode===e.expected.mirrorMode?old:e});pageRef.current=data;setPage(data);if(data.historical)setMode('list');setQuickId(id=>activeQuickUnit(data.items,id)?.id||null);setError('');
  }catch{if(run===generation.current)setError('Unable to load this inspection. Please refresh and try again.');}
  finally{if(run===generation.current)setLoading(false)}
 },[client,scope,single,selectedWeek,refreshSource]);
 useEffect(()=>{pageRef.current=null;setPage(null);setQuery('');setFilter('all');setUndo(null);setFeedback('');anchor.current=null;setMode('quick');setConfirming(new Set());setCelebrating(new Set());setQuickSuccess(null);quickSuccessRef.current=null;for(const timer of confirmationTimers.current.values())clearTimeout(timer);confirmationTimers.current.clear();setQuickId(null);setIssueId(null);listPosition.current=0;listVisited.current=false;setScrollRequest(null);listNavigation.current++;load(true,true);const timer=setInterval(()=>{if(!active.current.size&&!editingRef.current&&!managementBusy.current&&!confirmationTimers.current.size)load(true)},60000);return ()=>{generation.current++;clearInterval(timer);for(const timer of confirmationTimers.current.values())clearTimeout(timer);confirmationTimers.current.clear()}},[load]);
 useLayoutEffect(()=>{if(mode!=='quick'||!section.current)return;const el=section.current;const measure=()=>{const viewport=window.visualViewport,nav=document.querySelector('.mobile-nav')?.getBoundingClientRect();const height=quickWalkHeight({sectionTop:el.getBoundingClientRect().top,viewportTop:viewport?.offsetTop||0,viewportHeight:viewport?.height||window.innerHeight,navTop:nav&&nav.height?nav.top:null});el.style.setProperty('--walk-available',height+'px')};const observer=new ResizeObserver(measure);observer.observe(el);measure();window.addEventListener('resize',measure);window.visualViewport?.addEventListener('resize',measure);window.visualViewport?.addEventListener('scroll',measure);return()=>{observer.disconnect();window.removeEventListener('resize',measure);window.visualViewport?.removeEventListener('resize',measure);window.visualViewport?.removeEventListener('scroll',measure)}},[mode,page?.id]);
 const clearConfirmationMotion=useCallback((id:string)=>{
  const timer=confirmationTimers.current.get(id);
  if(timer)clearTimeout(timer);
  confirmationTimers.current.delete(id);
  setCelebrating(current=>{const next=new Set(current);next.delete(id);return next});
 },[]);
 const advanceQuick=useCallback((id:string,items:WalkEntry[])=>{
  quickSuccessRef.current=null;
  setQuickSuccess(null);
  setQuickId(nextUncheckedUnit(items,id)?.id||null);
  if(modeRef.current==='quick')requestAnimationFrame(()=>{
   if(modeRef.current==='quick')section.current?.querySelector<HTMLButtonElement>('.quick-confirm-button')?.focus({preventScroll:true});
  });
 },[]);
 const animateConfirmation=useCallback((id:string,sessionId:string|null,quick:boolean)=>{
  if(window.matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  setCelebrating(current=>new Set(current).add(id));
  confirmationTimers.current.set(id,setTimeout(()=>{
   clearConfirmationMotion(id);
   const current=pageRef.current;
   if(quick&&current&&current.id===sessionId&&quickSuccessRef.current===id)advanceQuick(id,current.items);
  },225));
 },[advanceQuick,clearConfirmationMotion]);
 const advance=useCallback((entry:WalkEntry|null)=>{if(!entry)return;anchor.current=entry.id;setQuery('');setFilter('all');setScrollRequest({id:entry.id,forward:false})},[]);
 const record=useCallback((id:string,mutation:Record<string,unknown>)=>{const originMode=modeRef.current,navigation=listNavigation.current;return queue.run(id,async()=>{
  const current=pageRef.current,entry=current?.items.find(e=>e.id===id);if(!current||!entry)return false;
  if(mutation.action==='set_confirmation'&&isConfirmed(entry)===mutation.confirmed)return true;
  if(mutation.action==='set_issue'&&entry.issue===mutation.issue)return true;
  if(mutation.action==='set_notes'&&entry.notes===mutation.notes)return true;
  ++generation.current;setLoading(false);active.current.add(id);setPending(new Set(active.current));setError('');
  const confirmingUnit=mutation.action==='set_confirmation'&&mutation.confirmed===true;
  if(confirmingUnit){
   setConfirming(current=>new Set(current).add(id));
   animateConfirmation(id,current.id,originMode==='quick');
  }
  try{
   const response=await client.rpc('walkthrough_record',{p:{weekId:current.id,entryId:id,version:entry.version,...mutation}});if(response.error||!response.data?.entry)throw Error('save_failed');
   if(pageRef.current?.id!==current.id)return false;const updated=response.data.entry as WalkEntry;const next={...patchInspectionEntry(pageRef.current,updated),sessionVersion:response.data.sessionVersion??pageRef.current.sessionVersion} as Page;const progress=inspectionProgress(next.items);next.history=next.history.map(h=>h.id===next.id?{...h,sessionVersion:next.sessionVersion,inspected:progress.inspected,issues:progress.issues}:h);pageRef.current=next;setPage(next);
   if(mutation.action==='set_confirmation'){
    if(mutation.confirmed){
     setFeedback(originMode==='quick'?'':'Unit '+entry.expected.label+' confirmed');setUndo({id,label:entry.expected.label});
     if(originMode==='quick'){
      if(confirmationTimers.current.has(id)&&modeRef.current==='quick'){
       quickSuccessRef.current=id;
       setQuickSuccess(id);
      }else advanceQuick(id,next.items);
     }else setQuickId(cursor=>cursor===id?nextUncheckedUnit(next.items,id)?.id||null:activeQuickUnit(next.items,cursor)?.id||null);
     if(originMode==='list'&&modeRef.current==='list'&&navigation===listNavigation.current){
      anchor.current=id;const visibleIds=new Set<string>(walkRows(next.items,listOptions.current).map((e:WalkEntry)=>e.id));
      const target=nextForwardUncheckedUnit(next.items,id,visibleIds);
      if(target)setScrollRequest({id:target.id,forward:true});
      else setFeedback('Unit '+entry.expected.label+' confirmed. '+(next.items.some(e=>!isConfirmed(e))?'No unchecked units ahead in this list.':'All units confirmed.'));
     }
    }else{
     clearConfirmationMotion(id);
     if(quickSuccessRef.current===id){quickSuccessRef.current=null;setQuickSuccess(null)}
     setFeedback('Confirmation undone for Unit '+entry.expected.label);setUndo(previous=>previous?.id===id?null:previous);
     if(originMode==='quick')setQuickId(id);else if(modeRef.current==='list'&&navigation===listNavigation.current)setScrollRequest({id,forward:false});
    }
   }else setFeedback((mutation.action==='set_notes'?'Notes':'Issue')+' saved for Unit '+entry.expected.label);
   return true;
  }catch{
   if(pageRef.current?.id!==current.id)return false;
   if(confirmingUnit){
    clearConfirmationMotion(id);
    setConfirming(current=>{const next=new Set(current);next.delete(id);return next});
    if(originMode==='quick')setQuickId(id);
   }
   await load(false);
   setError('Unable to save this unit. Review it and try again.');
   return false;
  }finally{
   if(confirmingUnit)setConfirming(current=>{if(!current.has(id))return current;const next=new Set(current);next.delete(id);return next});
   active.current.delete(id);
   setPending(new Set(active.current));
  }
 })},[client,load,queue,animateConfirmation,clearConfirmationMotion,advanceQuick]);
 const confirm=useCallback((id:string,value:boolean)=>{if(value&&quickSuccessRef.current===id)return;void confirmationGate.run(id,()=>record(id,{action:'set_confirmation',confirmed:value}))},[record,confirmationGate]);
 const issue=useCallback((id:string,value:string|null)=>record(id,{action:'set_issue',issue:value}),[record]);
 const notes=useCallback((id:string,value:string)=>record(id,{action:'set_notes',notes:value}),[record]);
 const assign=useCallback((unit:string,type:string)=>onAssign(scope,unit,type),[onAssign,scope]);
 async function complete(){const current=pageRef.current;if(!current||active.current.size)return;try{const r=await client.rpc('walkthrough_record',{p:{weekId:current.id,action:'complete'}});if(r.error)throw r.error;const updated={...current,status:'completed',historical:true,completedAt:r.data.completedAt,completedBy:r.data.completedBy,sessionVersion:r.data.sessionVersion};pageRef.current=updated;setPage(updated);setMode('list');setFeedback('Inspection completed');setSelectedWeek(current.id||'');if(selectedWeek===current.id)await load(false)}catch{setError('Refresh and inspect every current unit before completing.')}}
 async function policy(vacant:boolean|null,auction:string){setPolicyBusy(true);try{const r=await client.rpc('walkthrough_policy',{fid:scope,vacant_required:vacant,auction_lock_type:auction});if(r.error)throw r.error;await load(false,true)}catch{setError('Unable to save facility lock requirements. Please try again.')}finally{setPolicyBusy(false)}}
  const scrolled=useCallback(()=>setScrollRequest(null),[]);
 const manualListNavigation=useCallback(()=>{listNavigation.current++;setScrollRequest(null)},[]);
 const closeIssue=useCallback(()=>{setIssueId(null);requestAnimationFrame(()=>{if(modeRef.current==='quick')document.querySelector<HTMLButtonElement>('.quick-confirm-button')?.focus({preventScroll:true})})},[]);
 const saveListPosition=useCallback((top:number)=>{listPosition.current=top},[]);
 const items=page?.items||[],progress=inspectionProgress(items),disabled=sessionBusy||!!page?.historical||!!page?.stale||!!sourceError;
 const visible=useMemo(()=>walkRows(items,{mode:'list',query,filter}) as WalkEntry[],[items,query,filter]);
 const currentUnit=(quickSuccess?items.find(e=>e.id===quickSuccess):null)||activeQuickUnit(items,quickId) as WalkEntry|null,nextUnit=currentUnit?nextUncheckedUnit(items,currentUnit.id) as WalkEntry|null:null,editing=items.find(e=>e.id===issueId),confirmedCount=items.filter(isConfirmed).length;
 const lastConfirmed=items.find(e=>e.id===undo?.id&&isConfirmed(e))||[...items.slice(0,currentUnit?items.findIndex(e=>e.id===currentUnit.id):items.length)].reverse().find(isConfirmed)||null;
 function changeMode(value:'quick'|'list'){if(value!==mode){listNavigation.current++;setScrollRequest(null)}if(value==='list'&&!listVisited.current){listVisited.current=true;setScrollRequest(currentUnit?{id:currentUnit.id,forward:false}:null)}setMode(value)}

 async function manageSession(action:'new'|'restart'|'discard',item?:InspectionSummary){if(managementBusy.current||active.current.size)return false;managementBusy.current=true;setSessionBusy(true);setError('');try{if(action==='new'){await refreshSource();newRequest.current??=crypto.randomUUID()}const p=action==='new'?{action,facilityId:scope,requestId:newRequest.current}:{action,sessionId:item?.id,version:item?.id===pageRef.current?.id?pageRef.current?.sessionVersion:item?.sessionVersion,acknowledged:true,permanent:action==='discard'};const result=await client.rpc('walkthrough_session',{p});if(result.error||!result.data)throw Error('session_failed');newRequest.current=null;const data=result.data as Page;generation.current++;for(const timer of confirmationTimers.current.values())clearTimeout(timer);confirmationTimers.current.clear();pageRef.current=data;setPage(data);setQuickId(activeQuickUnit(data.items,null)?.id||null);setQuickSuccess(null);quickSuccessRef.current=null;setCelebrating(new Set());setUndo(null);setHistoryOpen(false);setMode('quick');setSelectedWeek(data.id||'');listPosition.current=0;listVisited.current=false;setFeedback(action==='new'?'Walk-through started':action==='restart'?'Confirmations reset. Issues and notes retained.':'Walk-through deleted');return true}catch{setError('Unable to update this inspection. Refresh and try again.');await load(false);return false}finally{managementBusy.current=false;setSessionBusy(false)}}
 function selectSession(id:string){if(active.current.size||managementBusy.current)return;setHistoryOpen(false);setSelectedWeek(id)}
 if(!single)return <section className="surface walkthrough-choose"><ClipboardCheck size={30}/><h2>Choose a facility to start walking</h2><p>Select a facility above to begin or resume an inspection.</p></section>;
 return <section ref={section} className={'walkthrough compact-walkthrough'+(mode==='quick'?' walkthrough-single':'')} aria-label="Manager walk-through"><div className="surface walkthrough-summary"><div className="walk-header"><h2>{mode==='quick'?'Walk-Through':page?.status==='completed'?'Completed':'In progress'}</h2><div className="walk-header-actions"><button className="secondary walk-new" aria-label="New Walk-Through" disabled={!!pending.size||loading||sessionBusy} onClick={()=>manageSession('new')}><Plus size={16}/><span className="walk-new-full">New Walk-Through</span><span className="walk-new-short" aria-hidden="true">New</span></button><button className="secondary" aria-label="Inspection history" disabled={!!pending.size||sessionBusy} onClick={()=>{setHistoryOpen(true);void load(false)}}><History size={18}/></button><button className="secondary" aria-label="Refresh walk-through" disabled={!!pending.size||loading||sessionBusy} onClick={()=>load(true,true)}><RefreshCw size={17}/></button></div></div>
 {page?.id&&<p className="walk-started-line" title={'Started by: '+(page.startedBy||'Not recorded')+' · Started: '+inspectionTime(page.startedAt)}>Started by: <strong>{page.startedBy||'Not recorded'}</strong> · {inspectionTime(page.startedAt)}{page.status==='completed'&&<> · Completed by: {page.completedBy||'Not recorded'} · {inspectionTime(page.completedAt)}</>}</p>}
 {!!items.length&&<><div className="walkthrough-progress" aria-label="Inspection progress"><span><strong>{progress.inspected}</strong> Inspected</span><span><strong>{progress.remaining}</strong> Remaining</span><span><strong>{progress.issues}</strong> Issues</span></div><progress max={items.length||1} value={progress.inspected} aria-label="Units inspected"/></>}
 </div>
 {error&&<p className="operations-error" role="alert">{error}</p>}{(sourceError||page?.stale)&&!page?.historical&&<p className="operations-error" role="alert">{sourceError||'Cubby information is out of date. Refresh before confirming units.'}</p>}
 {!page?.id&&!loading&&<div className="surface walk-no-session"><ClipboardCheck size={28}/><h2>Start a walk-through</h2><p>Choose New Walk-Through to start a separate inspection, or resume one from History.</p></div>}{page?.sourceUnavailable&&<p className="surface">Current unit information is unavailable. Use Refresh to try again.</p>}{!page&&loading&&<p role="status">Loading units…</p>}
 {!!items.length&&<><div className="walk-mode-bar"><div className="walk-mode-toggle" role="group" aria-label="Inspection mode"><button aria-pressed={mode==='quick'} disabled={!!page?.historical} onClick={()=>changeMode('quick')}>Quick Walk</button><button aria-pressed={mode==='list'} onClick={()=>changeMode('list')}>Full List</button></div>{mode==='list'&&<button className="secondary walk-next" disabled={!nextUncheckedUnit(items,anchor.current)} onClick={()=>advance(nextUncheckedUnit(items,anchor.current))}>Next Unchecked<ArrowRight size={17}/></button>}</div>
 {mode==='list'&&<div className="walkthrough-toolbar"><label className="search-input compact"><Search size={17}/><input aria-label="Search walk-through unit" placeholder="Find a unit…" value={query} onChange={e=>{manualListNavigation();setQuery(e.target.value)}}/></label><select aria-label="Filter walk-through" value={filter} onChange={e=>{manualListNavigation();setFilter(e.target.value)}}><option value="all">All units</option><option value="unchecked">Unchecked</option><option value="issues">Issues</option><option value="occupied">Occupied</option><option value="vacant">Vacant</option><option value="overlock">Overlocked</option><option value="auction">Auction</option></select></div>}
 {mode==='quick'?<WalkthroughQuickUnit entry={currentUnit} next={nextUnit} confirming={!!currentUnit&&confirming.has(currentUnit.id)} disabled={disabled} pending={sessionBusy||(!!currentUnit&&pending.has(currentUnit.id))} celebrating={!!currentUnit&&celebrating.has(currentUnit.id)} undoLabel={lastConfirmed?.expected.label||null} undoPending={!!lastConfirmed&&pending.has(lastConfirmed.id)} onConfirm={confirm} onIssue={setIssueId} onUndo={()=>{if(lastConfirmed)confirm(lastConfirmed.id,false)}} onAssign={assign}/>:<WalkthroughFullList items={visible} confirming={confirming} disabled={disabled} pending={pending} historical={!!page?.historical} celebrating={celebrating} scrollRequest={scrollRequest} onScrolled={scrolled} onManualNavigation={manualListNavigation} onConfirm={confirm} onOpenIssue={setIssueId} onAssign={assign} initialScrollTop={listPosition.current} onPosition={saveListPosition}/>}

 {(mode==='list'||!currentUnit)&&<div className="walkthrough-finish"><button className="primary" disabled={disabled||!!pending.size||progress.remaining!==0||(mode==='quick'&&confirmedCount!==items.length)||!!page?.completedAt} onClick={complete}><ClipboardCheck size={18}/>{page?.completedAt?'Inspection complete':'Complete inspection'}</button>{progress.remaining>0&&<small>Confirm or document an exception for every unit.</small>}</div>}</>}
 {historyOpen&&<WalkthroughHistory items={page?.history||[]} busy={sessionBusy||!!pending.size} onSelect={selectSession} onManage={manageSession} onClose={()=>{if(!sessionBusy)setHistoryOpen(false)}}>{admin&&page&&<details className="walkthrough-policy"><summary>Facility lock requirements</summary><label>Vacant units<select aria-label="Vacant lock requirement" disabled={policyBusy} value={page.policy.vacantRequired===null?'unknown':String(page.policy.vacantRequired)} onChange={e=>policy(e.target.value==='unknown'?null:e.target.value==='true',page.policy.auctionLockType)}><option value="unknown">Not configured</option><option value="true">Facility lock required</option><option value="false">Facility lock not required</option></select></label><label>Auction security<select aria-label="Auction lock requirement" disabled={policyBusy} value={page.policy.auctionLockType} onChange={e=>policy(page.policy.vacantRequired,e.target.value)}><option value="auction">Auction lock</option><option value="overlock">Overlock</option><option value="none">No facility lock required</option></select></label></details>}</WalkthroughHistory>}
 {editing&&<WalkthroughIssueDialog key={editing.id} entry={editing} disabled={disabled} pending={pending.has(editing.id)} onIssue={issue} onNotes={notes} onClose={closeIssue}/>}
 {mode==='quick'&&undo&&items.some(e=>e.id===undo.id&&isConfirmed(e))&&<span className="walk-confirmation-announcement" role="status">Unit {undo.label} confirmed</span>}
 {feedback&&<div className="walkthrough-feedback" role="status"><span>{feedback}</span>{mode==='list'&&undo&&!page?.historical&&<button className="secondary" disabled={disabled||pending.has(undo.id)} onClick={()=>confirm(undo.id,false)}><Undo2 size={18}/>Undo Unit {undo.label}</button>}<button className="walk-feedback-close" aria-label="Dismiss feedback" onClick={()=>setFeedback('')}><X size={17}/></button></div>}
 </section>;
}
