"use client";
import {useCallback,useEffect,useLayoutEffect,useRef,useState} from 'react';
import WalkthroughCard,{type WalkEntry} from './walkthrough-card';
import {reviewWindow,WALK_ROW_PITCH} from '@/lib/walkthrough-queue.mjs';
type Props={items:WalkEntry[];disabled:boolean;pending:Set<string>;historical:boolean;focusId:string|null;onFocused:()=>void;onConfirm:(id:string,value:boolean)=>void;onOpenIssue:(id:string)=>void;onAssign:(unit:string,type:string)=>void};
export default function WalkthroughReviewList({items,disabled,pending,historical,focusId,onFocused,onConfirm,onOpenIssue,onAssign}:Props){
 const container=useRef<HTMLDivElement>(null),frame=useRef<number|null>(null),[view,setView]=useState({top:0,height:520});
 const update=useCallback(()=>{const el=container.current;if(el)setView(old=>old.top===el.scrollTop&&old.height===el.clientHeight?old:{top:el.scrollTop,height:el.clientHeight||520})},[]);
 const onScroll=useCallback(()=>{if(frame.current!==null)return;frame.current=requestAnimationFrame(()=>{frame.current=null;update()})},[update]);
 useEffect(()=>{const el=container.current;if(!el)return;const observer=new ResizeObserver(update);observer.observe(el);update();return ()=>{observer.disconnect();if(frame.current!==null)cancelAnimationFrame(frame.current)}},[update]);
 useLayoutEffect(()=>{const el=container.current;if(!el)return;const index=items.findIndex(e=>e.id===focusId);if(index>=0){el.scrollTop=index*WALK_ROW_PITCH;update()}else if(el.scrollTop>Math.max(0,items.length*WALK_ROW_PITCH-el.clientHeight)){el.scrollTop=0;update()}},[focusId,items,update]);
 const window=reviewWindow(items.length,view.top,view.height);
 useLayoutEffect(()=>{if(focusId){const button=document.getElementById('walk-confirm-'+focusId);if(button){button.focus({preventScroll:true});onFocused()}}},[focusId,window.start,window.end,onFocused]);
 return <div ref={container} className="walk-list-viewport walk-review-list" role="list" aria-label="All inspection units in Cubby order" onScroll={onScroll}><div aria-hidden="true" style={{height:window.top}}/>{items.slice(window.start,window.end).map((entry,index)=><div className="walk-list-slot" role="listitem" aria-posinset={window.start+index+1} aria-setsize={items.length} key={entry.id}><WalkthroughCard entry={entry} disabled={disabled} pending={pending.has(entry.id)} historical={historical} onConfirm={onConfirm} onOpenIssue={onOpenIssue} onAssign={onAssign}/></div>)}<div aria-hidden="true" style={{height:window.bottom}}/></div>;
}
