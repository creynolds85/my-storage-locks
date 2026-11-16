"use client";
import {memo} from 'react';
import {Check,TriangleAlert,MessageSquareWarning} from 'lucide-react';
import {isConfirmed} from '@/lib/walkthrough-progress.mjs';
export type WalkEntry={id:string;version:number;expected:{label:string;kind:string;tenantName:string|null;auctionStatus:string|null;requiredType:string|null;vacantPolicyKnown:boolean;unrentable:boolean;missing:boolean;assignmentReview?:boolean;sourceReview?:boolean;locks:{serial:string;status:string}[]};result:string;confirmed?:boolean;issue:string|null;notes:string;manager:string|null;checkedAt:string|null;confirmedManager?:string|null;confirmedAt?:string|null;issueManager?:string|null;issueAt?:string|null};
const labels:Record<string,string>={occupied:'Occupied',vacant:'Vacant',overlock:'Overlocked',auction:'Auction',unknown:'Verify status'};
type Props={entry:WalkEntry;disabled:boolean;pending:boolean;historical:boolean;onConfirm:(id:string,value:boolean)=>void;onOpenIssue:(id:string)=>void;onAssign:(unit:string,type:string)=>void};
export default memo(function WalkthroughCard({entry,disabled,pending,historical,onConfirm,onOpenIssue,onAssign}:Props){
 const e=entry.expected,confirmed=isConfirmed(entry),serials=e.locks.map(l=>l.serial).join(', ');
 const info=[e.kind==='vacant'?(serials?'Lock '+serials:'No facility lock assigned'):e.tenantName||'Tenant unavailable',e.kind!=='vacant'&&serials?'Lock '+serials:null,e.kind==='auction'?e.auctionStatus?.replaceAll('_',' ').toLowerCase():null,e.unrentable?'Not currently rentable':null].filter(Boolean).join(' · ');
 const review=e.sourceReview?'Review assignment':'Review lock purpose';
 return <article id={'walk-'+entry.id} className={'walkthrough-card compact-walk-card '+e.kind+(confirmed?' confirmed':'')+(entry.issue?' has-issue':'')} aria-label={'Unit '+e.label+', '+labels[e.kind]+(confirmed?', confirmed':'')+(entry.issue?', issue: '+entry.issue:'')}>
 <div className="walk-row"><div className="walk-unit-info"><div className="walk-unit-heading"><h3 title={'Unit '+e.label}>{e.label}</h3><span className="walk-status">{labels[e.kind]}</span>{entry.issue&&<span className="walk-issue-tag" title={entry.issue}>Issue</span>}</div><p className="walk-unit-description" title={info}>{info}</p>
 {e.missing&&<button type="button" className="walk-assignment-chip" disabled={historical} onClick={()=>onAssign(e.label,e.requiredType!)}><TriangleAlert size={12}/>{e.requiredType==='vacant'?'Add Vacant Lock':e.requiredType==='overlock'?'Add Overlock':'Add Auction Lock'}</button>}
 {e.assignmentReview&&<span className="walk-review-chip" title={e.sourceReview?'Verify the Cubby lock record before adding another lock.':'Verify assigned lock purpose before adding another lock.'}><TriangleAlert size={12}/>{review}</span>}
 </div><div className="walk-row-actions"><button type="button" className={'walk-issue-button'+(entry.issue?' flagged':'')} aria-label={(entry.issue?'Issue: '+entry.issue+'. Edit issue for unit ':'Report issue for unit ')+e.label} onClick={()=>onOpenIssue(entry.id)}><MessageSquareWarning size={19}/></button><button type="button" id={'walk-confirm-'+entry.id} className={'walk-confirm-button'+(confirmed?' selected':'')} aria-label={(confirmed?'Undo confirmation for unit ':'Confirm unit ')+e.label} aria-pressed={confirmed} disabled={disabled||pending||e.kind==='unknown'} onClick={()=>onConfirm(entry.id,!confirmed)}><Check size={24}/><span>{pending?'Saving…':confirmed?'Done':'Confirm'}</span></button></div></div>
 </article>;
});
