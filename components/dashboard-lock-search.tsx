"use client";
import {useEffect,useState} from 'react';
import {Search,X,ChevronRight} from 'lucide-react';
import {fetchDashboardMatches,serialSearch} from '@/lib/inventory-query.mjs';
import {statuses} from '@/lib/csv.mjs';
type SearchLock={id:string;serial:string;facility_id:string;facility_name:string;status:string;unit:string|null;[key:string]:any};
export default function DashboardLockSearch({client,scope,sort,query,revision,onQuery,onSelect}:{client:any;scope:string;sort:string;query:string;revision:number;onQuery:(value:string)=>void;onSelect:(lock:any)=>void}){
 const [result,setResult]=useState<{key:string;items:SearchLock[];hasMore:boolean}>({key:'',items:[],hasMore:false});
 const [pending,setPending]=useState(false),[error,setError]=useState('');
 const needle=serialSearch(query).toLowerCase(),key=scope+'|'+sort+'|'+needle+'|'+revision;
 useEffect(()=>{
  const controller=new AbortController();setError('');
  if(!needle||!scope){setPending(false);setResult({key,items:[],hasMore:false});return ()=>controller.abort();}
  setPending(true);
  fetchDashboardMatches(client,{query:needle,scope,sort,limit:20,signal:controller.signal}).then(data=>{if(!controller.signal.aborted){setResult({key,...data});setPending(false);}}).catch(()=>{if(!controller.signal.aborted){setError('Search could not be loaded. Keep typing or try again.');setPending(false);}});
  return ()=>controller.abort();
 },[client,scope,sort,needle,key]);
 // Keep already matching rows while the next request is in flight; never show stale facility results.
 const rows=result.key===key?result.items:result.items.filter(l=>needle&&l.serial.toLowerCase().includes(needle)&&(scope==='all'||l.facility_id===scope));
 const settled=result.key===key&&!pending;
 return <section className="dashboard-search-section" aria-label="Find a lock"><div className="hero-search"><div className="search-icon"><Search size={26}/></div><div><h2>Got a lock in hand?</h2><p>Start typing its serial number. Find it instantly.</p></div><div className="search-input"><Search size={20}/><input aria-label="Search lock serial number" placeholder="Search serial number…" autoCapitalize="characters" autoComplete="off" spellCheck={false} value={query} onChange={e=>onQuery(e.target.value)}/>{query&&<button aria-label="Clear search" onClick={()=>onQuery('')}><X size={17}/></button>}</div></div>{query&&<section className="dashboard-search-results" aria-label="Matching locks" aria-busy={pending}><div className="dashboard-search-result-list">{rows.map(l=><button className="dashboard-lock-result" key={l.id} onClick={()=>onSelect(l)}><span className="dashboard-result-copy"><strong className="dashboard-result-serial">{l.serial}</strong><span className="dashboard-result-facility">{l.facility_name}</span><span className="dashboard-result-assignment"><span className={'badge '+l.status}><i/>{(statuses as Record<string,string>)[l.status]||l.status}</span>{l.unit&&<span>Unit {l.unit}</span>}</span></span><ChevronRight size={20}/></button>)}</div>{pending&&<p className="search-feedback" role="status">Searching…</p>}{error&&<p className="search-feedback error" role="alert">{error}</p>}{settled&&!error&&!rows.length&&<p className="search-feedback" role="status">No matching locks</p>}{settled&&result.hasMore&&<p className="search-feedback">Showing the first {rows.length} matches. Keep typing to narrow the results.</p>}</section>}</section>;
}
