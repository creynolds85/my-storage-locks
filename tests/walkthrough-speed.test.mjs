import test from 'node:test';import assert from 'node:assert/strict';
import {createInspectionQueue,isConfirmed,isInspected,inspectionProgress,nextInspectionEntry,patchInspectionEntry,advanceBehavior} from '../lib/walkthrough-progress.mjs';
test('confirmation and issue are independent, including legacy records',()=>{
 assert.equal(isConfirmed({result:'confirmed'}),true);
 assert.equal(isConfirmed({confirmed:false,result:'confirmed'}),false);
 assert.deepEqual(inspectionProgress([{confirmed:true,issue:'Door/Latch Damage'},{confirmed:false,issue:'No tenant lock'},{confirmed:false,issue:null}]),{inspected:2,remaining:1,issues:2});
 assert.equal(isInspected({confirmed:true,issue:'Other'}),true);
});
test('advance follows the existing sequence, skips documented exceptions and wraps to remaining units',()=>{
 const items=[{id:'10',confirmed:false},{id:'2',confirmed:true},{id:'7',confirmed:false,issue:'Other'},{id:'1',confirmed:false}];
 assert.equal(nextInspectionEntry(items,'10').id,'1');assert.equal(nextInspectionEntry(items,'1').id,'10');assert.equal(nextInspectionEntry(items).id,'10');
 assert.equal(nextInspectionEntry([{id:'only',confirmed:false}],'only').id,'only');
 assert.equal(nextInspectionEntry([{id:'done',confirmed:true}]),null);assert.equal(nextInspectionEntry([]),null);
 assert.deepEqual(items.map(e=>e.id),['10','2','7','1']);
});
test('targeted patch preserves roster order and all unaffected card objects',()=>{
 const a={id:'a',confirmed:false,issue:'Door/Latch Damage',version:1},b={id:'b',confirmed:false};const page={items:[a,b],completedAt:'old'};
 const confirmed={...a,confirmed:true,version:2};const next=patchInspectionEntry(page,confirmed);
 assert.equal(next.items[0],confirmed);assert.equal(next.items[1],b);assert.equal(next.completedAt,null);assert.equal(page.items[0],a);
 const undone=patchInspectionEntry(next,{...confirmed,confirmed:false,version:3});assert.equal(undone.items[0].issue,'Door/Latch Damage');assert.equal(inspectionProgress(undone.items).issues,1);
});
test('reduced motion uses instant native scrolling',()=>{assert.equal(advanceBehavior(true),'auto');assert.equal(advanceBehavior(false),'smooth')});

test('quick edits for the same unit save in order without blocking other units',async()=>{
 const queue=createInspectionQueue(),order=[];let release;const gate=new Promise(resolve=>{release=resolve});
 const a=queue.run('unit-a',async()=>{await gate;order.push('notes')});
 const b=queue.run('unit-a',async()=>{order.push('confirm')});
 const c=queue.run('unit-b',async()=>{order.push('other unit')});
 await c;assert.deepEqual(order,['other unit']);release();await Promise.all([a,b]);assert.deepEqual(order,['other unit','notes','confirm']);
});
