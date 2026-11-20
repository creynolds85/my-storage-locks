// DOM-only controlled UI fixtures; no authentication, Cubby, inventory, SMS or production writes.
// Run with WALK_DOM_MODULE pointing to happy-dom@21.0.4/lib/index.js installed outside the app.
import test,{afterEach} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs/promises';import path from 'node:path';import {pathToFileURL} from 'node:url';import {createRequire} from 'node:module';
if(!process.env.WALK_DOM_MODULE){test('controlled Quick Walk DOM checks',{skip:'Set WALK_DOM_MODULE to happy-dom@21.0.4/lib/index.js'},()=>{});}else{
const {Window}=await import(pathToFileURL(process.env.WALK_DOM_MODULE));
const window=new Window({width:390,height:844,url:'https://fixture.invalid'});
for(const name of ['window','document','HTMLElement','HTMLDialogElement','HTMLInputElement','HTMLTextAreaElement','Event','MouseEvent','KeyboardEvent','Node','MutationObserver','getComputedStyle'])Object.defineProperty(globalThis,name,{value:name==='window'?window:name==='document'?window.document:name==='getComputedStyle'?window.getComputedStyle.bind(window):window[name],configurable:true});
Object.defineProperty(globalThis,'navigator',{value:window.navigator,configurable:true});
let reduced=true,scrollCalls=0;window.matchMedia=q=>({matches:q.includes('reduced-motion')&&reduced,addEventListener(){},removeEventListener(){}});window.scrollTo=()=>{scrollCalls++};
globalThis.requestAnimationFrame=cb=>setTimeout(()=>cb(Date.now()),0);globalThis.cancelAnimationFrame=clearTimeout;
globalThis.ResizeObserver=class{constructor(cb){this.cb=cb}observe(){this.cb()}disconnect(){}};
Object.defineProperty(window.HTMLElement.prototype,'clientHeight',{get(){return this.classList.contains('walk-list-viewport')?480:80}});
window.HTMLElement.prototype.scrollTo=function(options){const top=typeof options==='object'?options.top:options;this.scrollRequests??=[];this.scrollRequests.push({top,behavior:options.behavior});this.scrollTop=top;this.dispatchEvent(new Event('scroll'))};
const originalRect=window.HTMLElement.prototype.getBoundingClientRect;
window.HTMLElement.prototype.getBoundingClientRect=function(){if(this.classList.contains('walk-full-list'))return {x:16,y:100,top:100,left:16,right:374,bottom:580,width:358,height:480};return originalRect.call(this)};
if(!window.HTMLDialogElement.prototype.showModal)window.HTMLDialogElement.prototype.showModal=function(){this.open=true};
if(!window.HTMLDialogElement.prototype.close)window.HTMLDialogElement.prototype.close=function(){this.open=false};
globalThis.fetch=async()=>({ok:true});globalThis.IS_REACT_ACT_ENVIRONMENT=true;
const React=await import('react');const {act}=React;const {createRoot}=await import('react-dom/client');
const {transform,loadBindings}=createRequire(import.meta.url)('next/dist/build/swc');await loadBindings();
const root=path.resolve(import.meta.dirname,'..'),dir=path.join(root,'test-results','walkthrough-session-contract');await fs.mkdir(dir,{recursive:true});
for(const name of ['walkthrough','walkthrough-card','walkthrough-issue-dialog','walkthrough-review-list','walkthrough-quick-unit','walkthrough-history','walkthrough-confirmation']){
 let source=await fs.readFile(path.join(root,'components',name+'.tsx'),'utf8');
 source=source.replace(/@\/components\/([a-z-]+)/g,(_,n)=>pathToFileURL(path.join(dir,n+'.mjs')).href).replaceAll('@/lib/',pathToFileURL(path.join(root,'lib')).href+'/').replaceAll("'./walkthrough-card'","'./walkthrough-card.mjs'");
 const compiled=(await transform(source,{filename:name+'.tsx',jsc:{parser:{syntax:'typescript',tsx:true},transform:{react:{runtime:'automatic'}},target:'es2022'},module:{type:'es6'}})).code;await fs.writeFile(path.join(dir,name+'.mjs'),compiled);
}
const {default:Walkthrough}=await import(pathToFileURL(path.join(dir,'walkthrough.mjs')));
const css=await fs.readFile(path.join(root,'app/brand.css'),'utf8');const style=document.createElement('style');style.textContent='*{box-sizing:border-box}'+css;document.head.append(style);
function entry(i){return {id:'unit-'+i,version:1,confirmed:false,result:'unchecked',issue:null,notes:'',checkedAt:null,manager:null,expected:{label:String(i===0?'3214':i===1?'0002':i+1),kind:['overlock','vacant','occupied','auction'][i%4],tenantName:'Fixture Tenant',auctionStatus:'LISTED',requiredType:null,missing:false,locks:[]}}}
const mounted=new Set();afterEach(async()=>{for(const f of [...mounted])await f.unmount()});
function fixture(count=1000){return {id:'week-fixture',weekStart:'2026-11-16',startedAt:'2026-11-17T14:00:00Z',startedBy:'Fixture Manager',status:'in_progress',sessionVersion:1,completedAt:null,stale:false,historical:false,items:Array.from({length:count},(_,i)=>entry(i)),policy:{vacantRequired:null,auctionLockType:'auction'},history:[]}}
async function flush(ms=10){await act(async()=>{await new Promise(r=>setTimeout(r,ms))})}
async function mount(page=fixture()){
 let data=structuredClone(page),fail=false,hold=null,sequence=1;
 const sessions=new Map();if(data.id)sessions.set(data.id,data);const calls=[],assignments=[];
 const summary=x=>({id:x.id,startedAt:x.startedAt,startedBy:x.startedBy,status:x.status,completedAt:x.completedAt,completedBy:x.completedBy,sessionVersion:x.sessionVersion,total:x.items.length,inspected:x.items.filter(e=>e.confirmed||e.issue).length,issues:x.items.filter(e=>e.issue).length});
 const response=x=>structuredClone({...x,history:[...sessions.values()].filter(x=>x.status!=='discarded').map(summary)});
 const client={auth:{getSession:async()=>({data:{session:{access_token:'fixture-only'}}})},rpc:async(name,args)=>{calls.push({name,args});
 if(name==='walkthrough_page'){data=args.sid?sessions.get(args.sid)||data:[...sessions.values()].filter(x=>x.status==='in_progress').at(-1)||{...fixture(0),id:null};return {data:response(data)}};
 if(name==='walkthrough_session'){
  if(hold)await hold;if(fail)return {error:{message:'fixture failure'}};const p=args.p;
  if(p.action==='new'){data={...fixture(4),id:'new-'+sequence++,items:fixture(4).items.map(e=>({...e,id:'s'+sequence+'-'+e.id}))};sessions.set(data.id,data)}
  else {data=sessions.get(p.sessionId);assert.equal(data.sessionVersion,p.version);assert.equal(p.acknowledged,true);assert.equal(data.status,'in_progress');if(p.action==='restart'){for(const e of data.items){e.confirmed=false;e.version++}}else {assert.equal(p.permanent,true);sessions.delete(data.id)}data.sessionVersion++;if(p.action==='discard')data=[...sessions.values()].filter(x=>x.status==='in_progress').at(-1)||{...fixture(0),id:null}}
  return {data:response(data)};
 }
 if(name==='walkthrough_record'){
  if(hold)await hold;if(fail)return {error:{message:'fixture failure'}};
  const p=args.p;data=sessions.get(p.weekId);if(p.action==='complete'){data.status='completed';data.historical=true;data.completedAt='2026-11-17T15:00:00Z';data.completedBy='Fixture Finisher';return {data:{completedAt:data.completedAt,completedBy:data.completedBy,sessionVersion:++data.sessionVersion}}}
  const e=data.items.find(e=>e.id===p.entryId);assert.equal(e.version,p.version);if(p.action==='set_confirmation')e.confirmed=p.confirmed;else if(p.action==='set_issue')e.issue=p.issue;else if(p.action==='set_notes')e.notes=p.notes;e.result=e.confirmed?'confirmed':e.issue?'issue':'unchecked';e.version++;data.sessionVersion++;return {data:{entry:structuredClone(e),sessionVersion:data.sessionVersion}}
 }throw Error('unexpected fixture operation') }};
 const host=document.createElement('div');document.body.append(host);const app=createRoot(host);
 await act(async()=>{app.render(React.createElement(Walkthrough,{client,scope:'fixture',facilities:[],admin:true,onAssign(...args){assignments.push(args)}}));await new Promise(r=>setTimeout(r,5))});await flush();
 const result={host,calls,assignments,sessions,get data(){return data},setFail:v=>{fail=v},setHold:p=>{hold=p},unmount:async()=>{await act(async()=>app.unmount());host.remove();mounted.delete(result)}};mounted.add(result);return result;
}
const button=(host,text)=>[...host.querySelectorAll('button')].find(b=>b.textContent.trim()===text||b.getAttribute('aria-label')===text);
async function click(el){assert.ok(el,'button exists');await act(async()=>{el.click();await Promise.resolve()});await flush()}

const activeLabel=host=>host.querySelector('.quick-unit-number strong')?.textContent;
const confirm=host=>host.querySelector('.quick-confirm-button');
const writes=f=>f.calls.filter(c=>c.name==='walkthrough_record');
async function typeNotes(host,text){const input=host.querySelector('textarea');input.focus();await act(async()=>{Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,text);input.dispatchEvent(new window.InputEvent('input',{bubbles:true,inputType:'insertText',data:text}))})}

test('Quick Walk animates immediately, waits for persistence, and advances in source order',async()=>{
 reduced=false;
 try{
  const f=await mount(fixture(1000)),control=confirm(f.host),panel=f.host.querySelector('.quick-unit');
  let release;f.setHold(new Promise(resolve=>release=resolve));
  await act(async()=>{control.click();control.click();control.click()});await flush();
  assert.equal(writes(f).length,1);
  assert.equal(activeLabel(f.host),'3214');
  assert.equal(control.textContent,'Saving…');
  assert.equal(f.data.items[0].confirmed,false);
  assert.equal(f.host.querySelector('.walk-confirmation-announcement'),null);
  const mark=panel.querySelector('.walk-confirmation-mark');
  assert.ok(mark);
  assert.equal(getComputedStyle(mark).backgroundColor.toLowerCase(),'#10b981');
  assert.equal(getComputedStyle(mark).borderTopWidth,'4px');
  assert.equal(mark.closest('.walk-confirmation-effect').getAttribute('aria-hidden'),'true');
  await flush(320);
  assert.equal(activeLabel(f.host),'3214');
  assert.equal(panel.querySelector('.walk-confirmation-mark'),null);
  await act(async()=>release());await flush();
  assert.equal(activeLabel(f.host),'0002');
  assert.equal(f.data.items[0].confirmed,true);
  assert.equal(confirm(f.host),control);
  assert.equal(f.host.querySelector('.quick-unit'),panel);
  assert.equal(panel.querySelector('.walk-confirmation-mark'),null);
  assert.equal(f.host.querySelector('.walkthrough-feedback'),null);
  assert.match(f.host.querySelector('.walk-confirmation-announcement').textContent,/Unit 3214 confirmed/);
  assert.equal(scrollCalls,0);
  await click(f.host.querySelector('.quick-undo-button'));
  assert.equal(activeLabel(f.host),'3214');
  assert.equal(f.data.items[0].confirmed,false);
  assert.equal(f.calls.filter(c=>c.name==='walkthrough_page').length,1);
 }finally{reduced=true}
});
test('Quick Walk rolls back a pending animation after a failed save and supports a reduced-motion retry',async()=>{
 reduced=false;
 try{
  const f=await mount(fixture(3));
  let release;f.setHold(new Promise(resolve=>release=resolve));f.setFail(true);
  await click(confirm(f.host));
  assert.ok(f.host.querySelector('.walk-confirmation-mark'));
  await act(async()=>release());await flush();
  assert.equal(activeLabel(f.host),'3214');
  assert.equal(f.data.items[0].confirmed,false);
  assert.equal(f.host.querySelector('.walk-confirmation-mark'),null);
  assert.equal(confirm(f.host).disabled,false);
  assert.match(f.host.querySelector('[role=alert]').textContent,/Unable to save/);
  reduced=true;f.setFail(false);
  await click(confirm(f.host));
  assert.equal(activeLabel(f.host),'0002');
  assert.equal(f.data.items[0].confirmed,true);
  assert.equal(f.host.querySelector('.walk-confirmation-mark'),null);
 }finally{reduced=true}
});
test('issues and notes stay independent across Quick Walk, Full List and history resume',async()=>{
 const f=await mount(fixture(4));await click(button(f.host,'Issue'));assert.deepEqual([...f.host.querySelectorAll('.walk-issue-options button')].map(b=>b.textContent),['Moved Out','No tenant lock','Unexpected Lock','Incorrect Overlock','Door/Latch Damage','Other']);await click(button(f.host,'Door/Latch Damage'));await typeNotes(f.host,'Latch fixture');await click(f.host.querySelector('.walk-sheet-done'));assert.equal(activeLabel(f.host),'3214');assert.equal(f.data.items[0].confirmed,false);assert.match(f.host.querySelector('.quick-unit-issue').textContent,/Door\/Latch Damage/);await click(confirm(f.host));await click(button(f.host,'Full List'));assert.equal(f.host.querySelector('#walk-confirm-unit-0').getAttribute('aria-pressed'),'true');assert.ok(f.host.querySelector('#walk-unit-0 .walk-issue-tag'));await click(button(f.host,'Quick Walk'));await click(f.host.querySelector('[aria-label="Inspection history"]'));await click(button(f.host,'Resume'));assert.equal(activeLabel(f.host),'0002');assert.equal(f.data.items[0].notes,'Latch fixture');assert.equal(f.data.items[0].confirmed,true);
});
test('New starts separate zero-progress sessions, double taps cannot duplicate, and History can resume each one',async()=>{
 const f=await mount(fixture(4));await click(confirm(f.host));const original=f.data.id;let release;f.setHold(new Promise(r=>release=r));const create=button(f.host,'New Walk-Through');await act(async()=>{create.click();create.click()});await flush();assert.equal(f.calls.filter(c=>c.name==='walkthrough_session').length,1);await act(async()=>release());await flush(40);const second=f.data.id;assert.notEqual(second,original);assert.equal(f.data.items.filter(e=>e.confirmed).length,0);assert.equal(f.sessions.get(original).items[0].confirmed,true);f.setHold(null);
 await click(f.host.querySelector('[aria-label="Inspection history"]'));const cards=[...f.host.querySelectorAll('.walk-session-history article')];assert.equal(cards.length,2);assert.match(cards[0].textContent,/Fixture Manager/);await click(button(cards[0],'Resume'));await flush();assert.equal(f.data.id,original);assert.equal(activeLabel(f.host),'0002');await click(f.host.querySelector('[aria-label="Inspection history"]'));await click(button([...f.host.querySelectorAll('.walk-session-history article')][1],'Resume'));await flush();assert.equal(f.data.id,second);assert.equal(activeLabel(f.host),'3214');
});
test('Restart retains findings; permanent Discard requires confirmation and completed history is protected',async()=>{
 const f=await mount(fixture(3));await click(button(f.host,'Issue'));await click(button(f.host,'Other'));await typeNotes(f.host,'Keep finding');await click(f.host.querySelector('.walk-sheet-done'));await click(confirm(f.host));await click(f.host.querySelector('[aria-label="Inspection history"]'));assert.ok(f.host.querySelector('dialog .walkthrough-policy'));await click(button(f.host,'Restart'));assert.match(f.host.querySelector('dialog').textContent,/Reported issues and notes are retained/);assert.equal(f.calls.filter(c=>c.name==='walkthrough_session').length,0);await click(button(f.host,'Cancel'));await click(button(f.host,'Restart'));await click(button(f.host,'Restart inspection'));await flush();assert.equal(activeLabel(f.host),'3214');assert.equal(f.data.items.filter(e=>e.confirmed).length,0);assert.equal(f.data.items[0].issue,'Other');assert.equal(f.data.items[0].notes,'Keep finding');
 await click(f.host.querySelector('[aria-label="Inspection history"]'));await click(button(f.host,'Discard'));assert.match(f.host.querySelector('dialog').textContent,/cannot be undone/);assert.equal(f.host.querySelector('dialog h2').textContent,'Delete Walk-Through?');await click(button(f.host,'Cancel'));assert.equal(f.data.status,'in_progress');await click(button(f.host,'Discard'));await click(button(f.host,'Delete Walk-Through'));await flush();assert.equal(f.data.id,null);assert.ok(button(f.host,'New Walk-Through'));assert.equal(f.sessions.has('week-fixture'),false);
 const completed={...fixture(2),status:'completed',historical:true,completedAt:'2026-11-17T15:00:00Z',completedBy:'Fixture Finisher'};for(const e of completed.items)e.confirmed=true;await f.unmount();const g=await mount(completed);await click(g.host.querySelector('[aria-label="Inspection history"]'));assert.equal(button(g.host,'Restart'),undefined);assert.equal(button(g.host,'Discard'),undefined);assert.match(g.host.querySelector('dialog').textContent,/Completed by: Fixture Finisher/);
});
test('Full List pulses its inline button and scrolls forward only after a successful save',async()=>{
 reduced=false;
 try{
  const f=await mount(fixture(100));await click(button(f.host,'Full List'));
  const list=f.host.querySelector('.walk-full-list');list.scrollRequests=[];
  let release;f.setHold(new Promise(resolve=>release=resolve));
  const control=f.host.querySelector('#walk-confirm-unit-0');
  await act(async()=>{control.click();control.click()});await flush();
  const row=f.host.querySelector('#walk-unit-0');
  assert.equal(writes(f).length,1);
  assert.ok(row.classList.contains('walk-confirmed-pulse'));
  assert.equal(row.querySelector('.walk-confirmation-effect'),null);
  assert.equal(control.textContent,'Confirmed');
  assert.equal(control.getAttribute('aria-busy'),'true');
  assert.equal(control.getAttribute('aria-pressed'),'false');
  assert.equal(f.data.items[0].confirmed,false);
  assert.equal(list.scrollRequests.length,0);
  await act(async()=>release());await flush();
  assert.equal(control.getAttribute('aria-pressed'),'true');
  assert.ok(list.scrollTop>0);
  for(let i=1;i<4;i++){
   const prior=list.scrollTop;
   await click(f.host.querySelector('#walk-confirm-unit-'+i));
   assert.equal(f.data.items[i].confirmed,true);
   assert.ok(list.scrollTop>prior);
  }
  const position=list.scrollTop,requests=list.scrollRequests.length;
  await flush(300);
  assert.equal(list.scrollTop,position);
  assert.equal(list.scrollRequests.length,requests);
  assert.equal(f.calls.filter(c=>c.name==='walkthrough_page').length,1);
  assert.ok(f.host.querySelectorAll('.compact-walk-card').length<20);
 }finally{reduced=true}
});
test('Full List rolls back a failed confirmation without scrolling and retains manual navigation',async()=>{
 const f=await mount(fixture(100));await click(button(f.host,'Full List'));
 const list=f.host.querySelector('.walk-full-list');list.scrollRequests=[];
 let release;f.setHold(new Promise(resolve=>release=resolve));f.setFail(true);
 await click(f.host.querySelector('#walk-confirm-unit-0'));
 assert.equal(f.host.querySelector('#walk-confirm-unit-0').textContent,'Confirmed');
 await act(async()=>release());await flush();
 const retried=f.host.querySelector('#walk-confirm-unit-0');
 assert.equal(retried.textContent,'Confirm');
 assert.equal(retried.disabled,false);
 assert.equal(retried.getAttribute('aria-pressed'),'false');
 assert.match(f.host.querySelector('[role=alert]').textContent,/Unable to save/);
 assert.equal(list.scrollRequests.length,0);
 f.setFail(false);f.setHold(new Promise(resolve=>release=resolve));
 await click(retried);
 await act(async()=>{
  list.dispatchEvent(new window.WheelEvent('wheel',{bubbles:true,deltaY:400}));
  list.scrollTop=400;list.dispatchEvent(new Event('scroll'));release();
 });await flush();
 assert.equal(f.data.items[0].confirmed,true);
 assert.equal(list.scrollRequests.length,0);
 assert.equal(list.scrollTop,400);
});
test('mobile viewport accounts for the toolbar and safe area with compact fixed controls',async()=>{
 const {quickWalkHeight}=await import(pathToFileURL(path.join(root,'lib/walkthrough-viewport.mjs')));
 for(const [height,top,nav,expected] of [[568,108,504,388],[640,108,576,460],[844,108,780,664]])assert.equal(quickWalkHeight({sectionTop:top,viewportHeight:height,navTop:nav}),expected);
 assert.equal(quickWalkHeight({sectionTop:125,viewportTop:20,viewportHeight:600,navTop:590}),457);
 const f=await mount(fixture(3));
 assert.equal(f.host.querySelector('.quick-unit-heading h2').textContent,'3214');
 assert.equal(f.host.querySelector('.quick-unit-heading .quick-unit-status').textContent,'Overlocked');
 assert.equal(getComputedStyle(f.host.querySelector('.quick-unit-content')).overflow,'hidden');
 assert.equal(getComputedStyle(f.host.querySelector('.quick-unit-controls')).height,'104px');
 assert.equal(getComputedStyle(confirm(f.host)).height,'54px');
 assert.equal(getComputedStyle(f.host.querySelector('.quick-undo-button')).minHeight,'44px');
 assert.equal(f.host.querySelectorAll('.walkthrough-progress').length,1);
});
test('white cards retain distinct status accents and an independent accessible issue indicator',async()=>{
 const palette={occupied:['#2563eb','#eff6ff','#1d4ed8'],vacant:['#10b981','#ecfdf5','#047857'],overlock:['#f43f5e','#fff1f2','#be123c'],auction:['#7c3aed','#f5f3ff','#6d28d9']};
 function checkCard(card,kind,issue){
  const [accent,background,ink]=palette[kind],style=getComputedStyle(card);
  const pill=getComputedStyle(card.querySelector('.walk-status,.quick-unit-status'));
  assert.equal(style.backgroundColor.toLowerCase(),'#ffffff');
  assert.ok(!style.backgroundImage||style.backgroundImage==='none');
  assert.equal(style.borderTopWidth,'1px');
  assert.equal(style.borderLeftWidth,'4px');
  assert.equal(style.borderLeftColor.toLowerCase(),accent);
  assert.equal(pill.backgroundColor.toLowerCase(),background);
  assert.equal(pill.color.toLowerCase(),ink);
  assert.equal(getComputedStyle(card.querySelector(issue)).color.toLowerCase(),'#b45309');
 }
 const page=fixture(4);for(const entry of page.items)entry.issue='Other';
 const f=await mount(page);
 await click(button(f.host,'Full List'));
 for(const [i,entry] of page.items.entries())checkCard(f.host.querySelector('#walk-unit-'+i),entry.expected.kind,'.walk-issue-button');
 await click(button(f.host,'Quick Walk'));
 for(const entry of page.items){
  checkCard(f.host.querySelector('.quick-unit'),entry.expected.kind,'.quick-unit-issue');
  assert.equal(getComputedStyle(confirm(f.host)).backgroundColor.toLowerCase(),'#2563eb');
  await click(confirm(f.host));
 }
 await click(button(f.host,'Full List'));
 for(const [i,entry] of page.items.entries()){
  const card=f.host.querySelector('#walk-unit-'+i);
  checkCard(card,entry.expected.kind,'.walk-issue-button');
  assert.equal(card.querySelector('.walk-confirm-button').getAttribute('aria-pressed'),'true');
 }
 function luminance(hex){
  const [r,g,b]=hex.slice(1).match(/../g).map(value=>parseInt(value,16)/255).map(value=>value<=.04045?value/12.92:((value+.055)/1.055)**2.4);
  return .2126*r+.7152*g+.0722*b;
 }
 for(const [background,ink] of [...Object.values(palette).map(([,bg,fg])=>[bg,fg]),['#fffbeb','#b45309'],['#2563eb','#ffffff'],['#10b981','#0f172a']]){
  const values=[luminance(background),luminance(ink)];
  assert.ok((Math.max(...values)+.05)/(Math.min(...values)+.05)>=4.5,background+' / '+ink);
 }
 assert.match(css,/walk-card-check 300ms/);
 assert.match(css,/walk-row-verified 200ms/);
 assert.match(css,/walk-button-verified 250ms/);
});
test('emerald confirmation cleans up as each differently classified unit advances',async()=>{
 reduced=false;try{const f=await mount(fixture(4)),control=confirm(f.host);for(let i=0;i<4;i++){const card=f.host.querySelector('.quick-unit'),kind=f.data.items[i].expected.kind;await click(control);assert.equal(card.classList.contains(kind),true);assert.equal(card.classList.contains('walk-confirmed-pulse'),true);assert.equal(card.querySelectorAll('.walk-confirmation-mark').length,1);assert.equal(control.querySelector('.walk-confirmation-mark'),null);assert.equal(control.disabled,true);await flush(380);assert.equal(card.classList.contains('walk-confirmed-pulse'),false);assert.equal(card.querySelector('.walk-confirmation-mark'),null);assert.equal(card.querySelector('.walk-border-sweep'),null);assert.equal(confirm(f.host),control);if(i<3)assert.equal(card.classList.contains(f.data.items[i+1].expected.kind),true)}assert.ok(f.host.querySelector('.quick-all-confirmed'));assert.equal(writes(f).length,4)}finally{reduced=true}
});

}
