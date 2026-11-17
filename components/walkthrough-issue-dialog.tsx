"use client";
import {useEffect,useRef,useState} from 'react';
import {X} from 'lucide-react';
import {WALKTHROUGH_ISSUES} from '@/lib/walkthrough-issues.mjs';
import type {WalkEntry} from './walkthrough-card';
export default function WalkthroughIssueDialog({entry,disabled,pending,onIssue,onNotes,onClose}:{entry:WalkEntry;disabled:boolean;pending:boolean;onIssue:(id:string,value:string|null)=>Promise<boolean>;onNotes:(id:string,value:string)=>Promise<boolean>;onClose:()=>void}){
 const dialog=useRef<HTMLDialogElement>(null),savingRef=useRef(false),[draft,setDraft]=useState(entry.notes),[choice,setChoice]=useState(entry.issue),[saving,setSaving]=useState(false),[error,setError]=useState('');
 useEffect(()=>{const el=dialog.current,previous=document.activeElement as HTMLElement|null;el?.showModal();return ()=>{el?.close();if(previous?.isConnected)previous.focus({preventScroll:true})}},[]);
 async function save(){if(disabled||pending||savingRef.current)return;savingRef.current=true;setSaving(true);setError('');try{
  if(!await onIssue(entry.id,choice)){setError('Unable to save this issue. Please try again.');return}
  if(!await onNotes(entry.id,draft)){setError('The issue is saved. Notes could not be saved; please try again.');return}
  onClose();
 }finally{savingRef.current=false;setSaving(false)}}
 function cancel(){if(!savingRef.current)onClose()}
 return <dialog ref={dialog} className="walk-issue-sheet" aria-labelledby="walk-issue-title" onCancel={e=>{e.preventDefault();cancel()}}><div className="walk-issue-sheet-header"><h2 id="walk-issue-title">Unit {entry.expected.label}</h2><button type="button" className="walk-sheet-close" aria-label="Close inspection issue" disabled={saving} onClick={cancel}><X size={20}/></button></div><div className="walk-sheet-unit-details"><p>{entry.expected.kind!=='vacant'?entry.expected.tenantName||'Tenant unavailable':'Vacant unit'}</p>{entry.expected.locks.map(l=><p key={l.serial}>Lock {l.serial}</p>)}</div><p className="walk-sheet-label">Report an issue</p><div className="walk-issue-options">{WALKTHROUGH_ISSUES.map(value=><button key={value} type="button" disabled={disabled||pending||saving} aria-pressed={choice===value} onClick={()=>setChoice(value)}>{value}</button>)}</div>{choice&&<button type="button" className="walk-clear-issue" disabled={disabled||saving} onClick={()=>setChoice(null)}>Clear issue</button>}<label className="walk-sheet-notes">Optional notes<textarea rows={3} maxLength={2000} value={draft} disabled={disabled||saving} placeholder="Add an observation…" onChange={e=>setDraft(e.target.value)}/></label>{(entry.issueAt||entry.confirmedAt||entry.checkedAt)&&<small>{entry.issueManager||entry.confirmedManager||entry.manager||'Manager'} · {new Date((entry.issueAt||entry.confirmedAt||entry.checkedAt)!).toLocaleString('en-US',{timeZone:'America/New_York',month:'short',day:'numeric',hour:'numeric',minute:'2-digit'})}</small>}{error&&<p role="alert">{error}</p>}{!disabled&&<button type="button" className="secondary walk-sheet-done" disabled={pending||saving} onClick={save}>{saving?'Saving…':'Save issue'}</button>}</dialog>;
}
