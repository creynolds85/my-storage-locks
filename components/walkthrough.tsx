"use client";
import {useCallback,useEffect,useRef,useState} from 'react';
import {Check,ChevronDown,ClipboardCheck,RefreshCw,Search,TriangleAlert} from 'lucide-react';
import {WALKTHROUGH_ISSUES} from '@/lib/walkthrough-issues.mjs';
type Entry={id:string;version:number;expected:{label:string;kind:string;tenantName:string|null;auctionStatus:string|null;requiredType:string|null;vacantPolicyKnown:boolean;unrentable:boolean;missing:boolean;locks:{serial:string;status:string}[]};result:string;issue:string|null;notes:string;manager:string|null;checkedAt:string|null};
type Page={id:string;weekStart:string;completedAt:string|null;ordering:string;stale:boolean;historical:boolean;refreshedAt:string|null;sourceUnavailable?:boolean;items:Entry[];policy:{vacantRequired:boolean|null;auctionLockType:string};history:{id:string;weekStart:string;completedAt:string|null}[]};
const labels:Record<string,string>={occupied:'Occupied',vacant:'Vacant',overlock:'Overlocked',auction:'Auction',unknown:'Needs verification'};
const confirmations:Record<string,string>={occupied:'Occupied and secured with tenant lock',vacant:'Vacancy and physical condition verified',overlock:'Correct overlock is present',auction:'Expected auction security verified',unknown:'Current condition needs verification'};
function dateLabel(value:string){return new Date(value+'T12:00:00').toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'})}
export default function Walkthrough({client,scope,facilities,admin,onAssign}:{client:any;scope:string;facilities:{id:string;name:string}[];admin:boolean;onAssign:(facility:string,unit:string,type:string)=>void}){
 const [page,setPage]=useState<Page|null>(null),[selectedWeek,setSelectedWeek]=useState(''),[query,setQuery]=useState(''),[filter,setFilter]=useState('all'),[error,setError]=useState(''),[sourceError,setSourceError]=useState(''),[loading,setLoading]=useState(false),[saving,setSaving]=useState<string|null>(null),[policyBusy,setPolicyBusy]=useState(false);
 const generation=useRef(0),busy=useRef(false);
 const single=scope&&scope!=='all';
 const load=useCallback(async(refresh=false)=>{
  if(!single)return;const run=++generation.current;setLoading(true);
  try{
   if(refresh&&!selectedWeek){
    const {data:{session}}=await client.auth.getSession();
    const response=await fetch('/api/walkthrough/refresh',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+(session?.access_token||'')},body:JSON.stringify({facilityId:scope})});
    if(run!==generation.current)return;
    setSourceError(response.ok?'':'Current Cubby information could not be refreshed. Refresh again before confirming units.');
   }
   const result=await client.rpc('walkthrough_page',{fid:scope,sid:selectedWeek||null});
   if(run!==generation.current)return;if(result.error)throw result.error;setPage(result.data);setError('');
  }catch{if(run===generation.current)setError('Unable to load this inspection. Please refresh and try again.');}
  finally{if(run===generation.current)setLoading(false)}
 },[client,scope,single,selectedWeek]);
 useEffect(()=>{setPage(null);setSelectedWeek('');setQuery('');setFilter('all');setSourceError('');return ()=>{generation.current++}},[scope]);
 useEffect(()=>{load(true);const timer=setInterval(()=>{if(!busy.current)load(true)},60000);return ()=>{generation.current++;clearInterval(timer)}},[load]);
 async function record(entry:Entry,result:string,issue:string|null,notes=entry.notes){
  if(!page||busy.current)return;busy.current=true;setSaving(entry.id);setError('');
  try{const saved=await client.rpc('walkthrough_record',{p:{weekId:page.id,entryId:entry.id,version:entry.version,result,issue,notes}});if(saved.error)throw saved.error;await load(false)}
  catch{await load(false);setError('Unable to save this unit. Refresh to see the latest inspection before trying again.')}
  finally{busy.current=false;setSaving(null)}
 }
 async function complete(){if(!page||busy.current)return;busy.current=true;setSaving('complete');try{const r=await client.rpc('walkthrough_record',{p:{weekId:page.id,action:'complete'}});if(r.error)throw r.error;await load(false)}catch{setError('Every current unit must be inspected. Refresh and review remaining units before completing.')}finally{busy.current=false;setSaving(null)}}
 async function policy(vacant:boolean|null,auction:string){setPolicyBusy(true);try{const r=await client.rpc('walkthrough_policy',{fid:scope,vacant_required:vacant,auction_lock_type:auction});if(r.error)throw r.error;await load(false)}catch{setError('Unable to save facility lock requirements. Please try again.')}finally{setPolicyBusy(false)}}
 if(!single)return <section className="surface walkthrough-choose"><ClipboardCheck size={30}/><h2>Choose a facility to start walking</h2><p>Each facility has its own weekly inspection. Select a facility above to begin or resume.</p></section>;
 const items=page?.items||[],inspected=items.filter(e=>e.result!=='unchecked').length,issues=items.filter(e=>e.result==='issue').length;
 const disabled=!!saving||!!page?.historical||!!page?.stale||!!sourceError;
 const visible=items.filter(e=>(!query||e.expected.label.toLowerCase().includes(query.toLowerCase()))&&(filter==='all'||filter==='unchecked'&&e.result==='unchecked'||filter==='issues'&&e.result==='issue'||filter===e.expected.kind));
 function next(){const entry=items.find(e=>e.result==='unchecked');if(!entry)return;setFilter('all');setQuery('');requestAnimationFrame(()=>{document.getElementById('walk-'+entry.id)?.scrollIntoView({behavior:'smooth',block:'center'});document.getElementById('walk-confirm-'+entry.id)?.focus({preventScroll:true})})}
 return <section className="walkthrough" aria-label="Weekly walk-through"><div className="surface walkthrough-summary"><div className="section-heading"><div><h2>{page?.weekStart?'Week of '+dateLabel(page.weekStart):'Weekly inspection'}</h2><p>{facilities.find(f=>f.id===scope)?.name}</p></div><button className="secondary" aria-label="Refresh walk-through" disabled={!!saving||loading} onClick={()=>load(true)}><RefreshCw size={17}/>{loading?'Updating…':'Refresh'}</button></div>
 {page&&!page.sourceUnavailable&&<><div className="walkthrough-progress" aria-label="Inspection progress"><strong>{inspected}<small>Inspected</small></strong><strong>{items.length-inspected}<small>Remaining</small></strong><strong>{issues}<small>Issues</small></strong></div><progress max={items.length||1} value={inspected} aria-label="Units inspected"/>
 <p className="walkthrough-order">{page.ordering==='cubby'?'Cubby walkthrough order.':'Cubby order where available; missing or tied positions use natural unit order.'} Units stay in this week’s sequence after inspection.</p>
 <div className="walkthrough-controls"><button className="secondary" onClick={next} disabled={inspected===items.length}>Next Unchecked<ChevronDown size={16}/></button><label className="walkthrough-history">Inspection<select aria-label="Inspection week" value={selectedWeek} onChange={e=>setSelectedWeek(e.target.value)}><option value="">Current week</option>{page.history.filter(h=>h.weekStart!==page.weekStart||selectedWeek).map(h=><option key={h.id} value={h.id}>{dateLabel(h.weekStart)}{h.completedAt?' · Complete':''}</option>)}</select></label></div>
 {page.completedAt&&<p className="walkthrough-complete"><Check size={17}/>Inspection complete. Historical results are retained.</p>}
 {admin&&!selectedWeek&&<details className="walkthrough-policy"><summary>Facility lock requirements</summary><p>Set the facility’s actual requirements. This does not assign locks.</p><label>Vacant units<select aria-label="Vacant lock requirement" disabled={policyBusy} value={page.policy.vacantRequired===null?'unknown':String(page.policy.vacantRequired)} onChange={e=>policy(e.target.value==='unknown'?null:e.target.value==='true',page.policy.auctionLockType)}><option value="unknown">Not configured — no missing-lock assumption</option><option value="true">Facility lock required</option><option value="false">Facility lock not required</option></select></label><label>Auction security<select aria-label="Auction lock requirement" disabled={policyBusy} value={page.policy.auctionLockType} onChange={e=>policy(page.policy.vacantRequired,e.target.value)}><option value="auction">Auction lock</option><option value="overlock">Overlock</option><option value="none">No facility lock required</option></select></label></details>}
 {page.policy.vacantRequired===null&&<p className="walkthrough-note">Vacant-lock requirements have not been configured for this facility. Vacant units still need physical inspection.</p>}</>}
 </div>
 {error&&<p className="operations-error" role="alert">{error}</p>}{(sourceError||page?.stale)&&<p className="operations-error" role="alert">{sourceError||'Cubby information is out of date. Refresh before confirming units.'}</p>}
 {page?.sourceUnavailable&&<div className="surface"><p>Current unit information is unavailable. Use Refresh to try again. No units have been confirmed.</p></div>}
 {!page&&loading&&<p role="status">Loading this facility’s units…</p>}
 {!!items.length&&<><div className="walkthrough-toolbar"><label className="search-input compact"><Search size={17}/><input aria-label="Search walk-through unit" placeholder="Find a unit…" value={query} onChange={e=>setQuery(e.target.value)}/></label><select aria-label="Filter walk-through" value={filter} onChange={e=>setFilter(e.target.value)}><option value="all">All units</option><option value="unchecked">Unchecked</option><option value="issues">Issues</option><option value="occupied">Occupied</option><option value="vacant">Vacant</option><option value="overlock">Overlocked</option><option value="auction">Auction</option></select></div>
 <div className="walkthrough-units">{visible.map(entry=>{const e=entry.expected;return <article id={'walk-'+entry.id} key={entry.id} className={'walkthrough-card '+e.kind+' '+entry.result}><div className="walkthrough-card-heading"><h3>Unit {e.label}</h3><span>{labels[e.kind]}</span></div>
 <p className="walkthrough-tenant">{e.kind==='vacant'?(e.locks.length?'Facility lock: '+e.locks.map(l=>l.serial).join(', '):'No facility lock assigned'):e.tenantName||'Tenant information unavailable'}</p>
 {e.kind==='auction'&&<p className="walkthrough-auction">Auction: {e.auctionStatus?.replaceAll('_',' ').toLowerCase()||'Active'} · {e.requiredType==='overlock'?'Overlock expected':e.requiredType==='auction'?'Auction lock expected':'Verify physical security'}</p>}
 {e.kind!=='vacant'&&e.locks.length>0&&<p className="walkthrough-locks">Assigned: {e.locks.map(l=>l.serial+' ('+l.status.replaceAll('_',' ')+')').join(', ')}</p>}
 {e.unrentable&&<p className="walkthrough-note">Not currently rentable. Verify its condition.</p>}
 {e.missing&&<div className="walkthrough-warning"><TriangleAlert size={18}/><div><strong>No matching inventory assignment</strong><span>Check the physical lock at the unit.</span></div><button className="secondary" disabled={!!page?.historical} onClick={()=>onAssign(scope,e.label,e.requiredType!)}>{e.requiredType==='vacant'?'Add Vacant Lock':e.requiredType==='overlock'?'Add Overlock':'Add Auction Lock'}</button></div>}
 <label className="walkthrough-confirm"><input id={'walk-confirm-'+entry.id} type="checkbox" checked={entry.result==='confirmed'} disabled={disabled||e.kind==='unknown'} onChange={event=>record(entry,event.target.checked?'confirmed':'unchecked',null)}/><span>{confirmations[e.kind]}</span>{saving===entry.id&&<small>Saving…</small>}</label>
 <div className="walkthrough-issue"><label htmlFor={'walk-issue-'+entry.id}>Report an issue</label><select id={'walk-issue-'+entry.id} aria-label={'Issue for unit '+e.label} disabled={disabled} value={entry.issue||''} onChange={ev=>record(entry,ev.target.value?'issue':'unchecked',ev.target.value||null)}><option value="">No issue selected</option>{WALKTHROUGH_ISSUES.map(issue=><option key={issue}>{issue}</option>)}</select></div>
 <details className="walkthrough-notes"><summary>{entry.notes?'View or edit notes':'Add optional notes'}</summary><Notes key={entry.id+entry.version} initial={entry.notes} disabled={disabled} onSave={notes=>record(entry,entry.result,entry.issue,notes)}/></details>
 {entry.checkedAt&&<small className="walkthrough-attribution">{entry.result==='issue'?'Issue reported':entry.result==='confirmed'?'Confirmed':'Selection corrected'} by {entry.manager||'Manager'} · {new Date(entry.checkedAt).toLocaleString('en-US',{timeZone:'America/New_York',month:'short',day:'numeric',hour:'numeric',minute:'2-digit'})}</small>}
 </article>})}</div>{!visible.length&&<p className="surface">No units match this filter.</p>}
 <div className="walkthrough-finish"><button className="primary" disabled={disabled||inspected!==items.length||!!page?.completedAt} onClick={complete}><ClipboardCheck size={18}/>{page?.completedAt?'Inspection complete':saving==='complete'?'Saving…':'Complete weekly inspection'}</button>{inspected!==items.length&&<small>Confirm or document an exception for every unit to complete.</small>}</div></>}
 </section>;
}
function Notes({initial,disabled,onSave}:{initial:string;disabled:boolean;onSave:(notes:string)=>void}){const [value,setValue]=useState(initial);return <textarea aria-label="Inspection notes" maxLength={2000} value={value} rows={2} disabled={disabled} placeholder="Optional observation…" onChange={e=>setValue(e.target.value)} onBlur={()=>{if(value!==initial)onSave(value)}}/>}
