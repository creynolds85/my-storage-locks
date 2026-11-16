"use client";
import {useCallback,useEffect,useLayoutEffect,useRef,useState} from 'react';
import WalkthroughCard,{type WalkEntry} from './walkthrough-card';
import {reviewWindow,WALK_ROW_PITCH,WALK_ROW_HEIGHT} from '@/lib/walkthrough-queue.mjs';
type Props={items:WalkEntry[];disabled:boolean;pending:Set<string>;historical:boolean;focusId:string|null;onFocused:()=>void;onConfirm:(id:string,value:boolean)=>void;onOpenIssue:(id:string)=>void;onAssign:(unit:string,type:string)=>void;initialScrollTop:number;onPosition:(top:number)=>void};
export default function WalkthroughFullList({items,disabled,pending,historical,focusId,onFocused,onConfirm,onOpenIssue,onAssign,initialScrollTop,onPosition}:Props){
 const container=useRef<HTMLDivElement>(null),frame=useRef<number|null>(null),restored=useRef(false),[view,setView]=useState({top:initialScrollTop,height:520});
 const update=useCallback(()=>{const el=container.current;if(el){onPosition(el.scrollTop);setView(old=>old.top===el.scrollTop&&old.height===el.clientHeight?old:{top:el.scrollTop,height:el.clientHeight||520})}},[onPosition]);
 const onScroll=useCallback(()=>{if(frame.current!==null)return;frame.current=requestAnimationFrame(()=>{frame.current=null;update()})},[update]);
 useLayoutEffect(()=>{if(!restored.current&&container.current){container.current.scrollTop=initialScrollTop;restored.current=true;update()}},[initialScrollTop,update]);
 useEffect(()=>{const el=container.current;if(!el)return;const observer=new ResizeObserver(update);observer.observe(el);update();return ()=>{onPosition(el.scrollTop);observer.disconnect();if(frame.current!==null)cancelAnimationFrame(frame.current)}},[update,onPosition]);
 useLayoutEffect(()=>{const el=container.current;if(!el)return;const index=items.findIndex(e=>e.id===focusId);if(index>=0){const top=index*WALK_ROW_PITCH,bottom=top+WALK_ROW_HEIGHT;if(top<el.scrollTop+8||top>el.scrollTop+el.clientHeight*.4||bottom>el.scrollTop+el.clientHeight-8){el.scrollTop=Math.max(0,top-Math.min(96,el.clientHeight*.2));update()}}else if(el.scrollTop>Math.max(0,items.length*WALK_ROW_PITCH-el.clientHeight)){el.scrollTop=Math.max(0,items.length*WALK_ROW_PITCH-el.clientHeight);update()}if(focusId&&index<0)onFocused()},[focusId,items,update,onFocused]);
 const range=reviewWindow(items.length,view.top,view.height);
 useLayoutEffect(()=>{if(focusId){const button=document.getElementById('walk-confirm-'+focusId);if(button){button.focus({preventScroll:true});onFocused()}}},[focusId,range.start,range.end,onFocused]);
 return <div ref={container} className="walk-list-viewport walk-full-list" role="list" aria-label="Full List in Cubby walkthrough order" onScroll={onScroll}><div aria-hidden="true" style={{height:range.top}}/>{items.slice(range.start,range.end).map((entry,index)=><div className="walk-list-slot" role="listitem" aria-posinset={range.start+index+1} aria-setsize={items.length} key={entry.id}><WalkthroughCard entry={entry} disabled={disabled} pending={pending.has(entry.id)} historical={historical} onConfirm={onConfirm} onOpenIssue={onOpenIssue} onAssign={onAssign}/></div>)}<div aria-hidden="true" style={{height:range.bottom}}/></div>;
}
