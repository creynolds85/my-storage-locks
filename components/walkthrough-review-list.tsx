"use client";
import {useCallback,useEffect,useLayoutEffect,useRef,useState} from 'react';
import WalkthroughCard,{type WalkEntry} from './walkthrough-card';
import {reviewWindow,WALK_ROW_PITCH,WALK_ROW_HEIGHT} from '@/lib/walkthrough-queue.mjs';
export type WalkScrollRequest={id:string;forward:boolean};
type Props={items:WalkEntry[];disabled:boolean;pending:Set<string>;historical:boolean;scrollRequest:WalkScrollRequest|null;onScrolled:()=>void;onManualNavigation:()=>void;onConfirm:(id:string,value:boolean)=>void;onOpenIssue:(id:string)=>void;onAssign:(unit:string,type:string)=>void;initialScrollTop:number;onPosition:(top:number)=>void};
export default function WalkthroughFullList({items,disabled,pending,historical,scrollRequest,onScrolled,onManualNavigation,onConfirm,onOpenIssue,onAssign,initialScrollTop,onPosition}:Props){
 const container=useRef<HTMLDivElement>(null),frame=useRef<number|null>(null),restored=useRef(false),handled=useRef<WalkScrollRequest|null>(null),moving=useRef(false),[view,setView]=useState({top:initialScrollTop,height:520});
 const update=useCallback(()=>{const el=container.current;if(el){onPosition(el.scrollTop);setView(old=>old.top===el.scrollTop&&old.height===el.clientHeight?old:{top:el.scrollTop,height:el.clientHeight||520})}},[onPosition]);
 const onScroll=useCallback(()=>{if(frame.current!==null)return;frame.current=requestAnimationFrame(()=>{frame.current=null;update()})},[update]);
 useLayoutEffect(()=>{if(!restored.current&&container.current){container.current.scrollTop=initialScrollTop;restored.current=true;update()}},[initialScrollTop,update]);
 useEffect(()=>{const el=container.current;if(!el)return;const observer=new ResizeObserver(update);observer.observe(el);update();return ()=>{onPosition(el.scrollTop);observer.disconnect();if(frame.current!==null)cancelAnimationFrame(frame.current)}},[update,onPosition]);
 // A consumed scroll request is the only auto-scroll trigger. Data/feedback renders
 // never focus a virtualized button or reapply a previous target.
 useLayoutEffect(()=>{
  const el=container.current;if(!el||!scrollRequest||handled.current===scrollRequest)return;
  handled.current=scrollRequest;const index=items.findIndex(e=>e.id===scrollRequest.id);
  if(index>=0){
   const rect=el.getBoundingClientRect(),top=rect.height?rect.top:0,bottom=rect.height?rect.bottom:el.clientHeight;
   const viewport=window.visualViewport,viewportTop=viewport?.offsetTop||0;
   let safeTop=Math.max(top,viewportTop),safeBottom=Math.min(bottom,viewportTop+(viewport?.height||window.innerHeight));
   const header=document.querySelector('.topbar');if(header){const box=header.getBoundingClientRect(),position=getComputedStyle(header).position;if(box.height&&(position==='fixed'||position==='sticky'))safeTop=Math.max(safeTop,box.bottom)}
   for(const overlay of document.querySelectorAll('.mobile-nav,.walkthrough-feedback')){const box=overlay.getBoundingClientRect();if(box.height&&box.top>safeTop&&box.top<safeBottom)safeBottom=box.top-8}
   const inset=Math.max(8,Math.min(64,(safeBottom-safeTop-WALK_ROW_HEIGHT)*.2));
   const padding=parseFloat(getComputedStyle(el).paddingTop)||0;
   const target=Math.min(Math.max(0,index*WALK_ROW_PITCH+padding-(safeTop-top+inset)),Math.max(0,items.length*WALK_ROW_PITCH+padding*2-el.clientHeight));
   // Late responses or a manager's manual forward scroll cannot pull the list back.
   const destination=scrollRequest.forward?Math.max(el.scrollTop,target):target;
   if(Math.abs(destination-el.scrollTop)>1){moving.current=true;el.scrollTo({top:destination,behavior:window.matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'});update()}
  }
  onScrolled();
 },[scrollRequest,items,onScrolled,update]);
 const cancelAutoScroll=useCallback(()=>{const el=container.current;if(el&&moving.current){el.scrollTo({top:el.scrollTop,behavior:'instant'});moving.current=false}onManualNavigation()},[onManualNavigation]);
 const range=reviewWindow(items.length,view.top,view.height);
 return <div ref={container} className="walk-list-viewport walk-full-list" role="list" aria-label="Full List in Cubby walkthrough order" onScroll={onScroll} onWheel={cancelAutoScroll} onTouchStart={cancelAutoScroll} onPointerDown={cancelAutoScroll} onKeyDown={e=>{if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End',' '].includes(e.key))cancelAutoScroll()}}><div aria-hidden="true" style={{height:range.top}}/>{items.slice(range.start,range.end).map((entry,index)=><div className="walk-list-slot" role="listitem" aria-posinset={range.start+index+1} aria-setsize={items.length} key={entry.id}><WalkthroughCard entry={entry} disabled={disabled} pending={pending.has(entry.id)} historical={historical} onConfirm={onConfirm} onOpenIssue={onOpenIssue} onAssign={onAssign}/></div>)}<div aria-hidden="true" style={{height:range.bottom}}/></div>;
}
