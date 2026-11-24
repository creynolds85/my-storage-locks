// Isolated DOM fixtures; no real users, emails, credentials or network calls.
import test,{afterEach} from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs/promises';import path from 'node:path';import {pathToFileURL} from 'node:url';import {createRequire} from 'node:module';
if(!process.env.WALK_DOM_MODULE){test('account invitation UI checks',{skip:'Set WALK_DOM_MODULE to the existing Happy DOM installation'},()=>{});}else{
 const {Window}=await import(pathToFileURL(process.env.WALK_DOM_MODULE));const win=new Window({url:'https://mystoragelocks.com/login',width:390,height:844});
 for(const name of ['window','document','HTMLElement','HTMLInputElement','Event','MouseEvent','Node','MutationObserver'])Object.defineProperty(globalThis,name,{value:name==='window'?win:name==='document'?win.document:win[name],configurable:true});
 Object.defineProperty(globalThis,'navigator',{value:win.navigator,configurable:true});globalThis.localStorage=win.localStorage;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
 const React=await import('react'),{act}=React,{createRoot}=await import('react-dom/client');const {transform,loadBindings}=createRequire(import.meta.url)('next/dist/build/swc');await loadBindings();
 const root=path.resolve(import.meta.dirname,'..'),dir=path.join(root,'test-results','account-ui');await fs.mkdir(dir,{recursive:true});
 const components=['lock-manager','cubby-combo-export','inventory-reconciliation','combination-change','dashboard-lock-search','walkthrough','walkthrough-card','walkthrough-issue-dialog','walkthrough-review-list','walkthrough-quick-unit','walkthrough-history'];
 for(const name of components){let source=await fs.readFile(path.join(root,'components',name+'.tsx'),'utf8');source=source.replaceAll('"@/lib/supabase"','"data:text/javascript,export function db(){return globalThis.accountFixtureClient}"').replace(/@\/components\/([a-z-]+)/g,(_,n)=>pathToFileURL(path.join(dir,n+'.mjs')).href).replaceAll('@/lib/',pathToFileURL(path.join(root,'lib')).href+'/').replaceAll("'./walkthrough-card'","'./walkthrough-card.mjs'");const compiled=(await transform(source,{filename:name+'.tsx',jsc:{parser:{syntax:'typescript',tsx:true},transform:{react:{runtime:'automatic'}},target:'es2022'},module:{type:'es6'}})).code;await fs.writeFile(path.join(dir,name+'.mjs'),compiled)}
 const {default:Manager}=await import(pathToFileURL(path.join(dir,'lock-manager.mjs')));let mounted;
 afterEach(async()=>{if(mounted){await act(async()=>mounted.unmount());mounted=null}document.body.replaceChildren();localStorage.clear()});
 const click=async el=>{assert.ok(el,'control exists');await act(async()=>{el.click();await new Promise(r=>setTimeout(r,15))})};
 const button=text=>[...document.querySelectorAll('button')].find(b=>b.textContent.trim()===text);
 const type=async(el,value)=>{await act(async()=>{Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,value);el.dispatchEvent(new win.InputEvent('input',{bubbles:true,inputType:'insertText',data:value}))})};
 const snapshotTime='2026-11-24T15:00:00Z',workerTime='2026-11-24T15:20:00Z';
 const report={
  asOf:workerTime,mode:'mirror',inventory:2,matched:1,sourceCount:1,unclassified:1,retained:1,differences:1,
  missingCodes:0,purposeUnverified:1,verifiedCodes:0,workerState:'operational',lastCheckedAt:workerTime,
  lastSuccessAt:workerTime,lastErrorCode:null,lastFullSyncAt:snapshotTime,sourceSnapshotAt:snapshotTime,
  sourceComplete:true,sourceFresh:true,capabilities:{combinations:false,explicitPurpose:false},
  latestCsvReconciledAt:null,legacyCsvEvidenceAt:snapshotTime,
  items:[
   {serial:'FIXTURE1',facility:'Fixture Facility',status:'unclassified',reasons:['unclassified','cubby_locked']},
   {serial:'FIXTURE2',facility:'Fixture Facility',status:'missing',reasons:['retained_in_msl']},
  ],
 };
 async function mount({setup=false,anonymous=false,emailFailure=false,deliveryReady=true,deleteFailure=false}={}){
  win.history.replaceState(null,'',setup?'/login#access_token=fixture&refresh_token=fixture&type=invite':anonymous?'/login':'/dashboard?view=admin');let signedIn=!anonymous&&!setup;const calls=[],accounts=[{account_id:'fixture-inactive-id',email:'inactive@example.invalid',name:'Inactive Employee',role:'employee',active:false,facility_ids:[],registered:false,setup_complete:false}];
  const client={auth:{getUser:async()=>({data:{user:signedIn?{id:'fixture-admin',email:'fixture@example.invalid'}:null}}),getSession:async()=>({data:{session:{access_token:'fixture'}}}),setSession:async()=>{calls.push(['setSession']);signedIn=true;return {error:null}},onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),updateUser:async()=>{calls.push(['updateUser']);return {error:null}},resend:async()=>{calls.push(['resend']);return {error:{code:'over_email_send_rate_limit',status:429}}}},from:table=>({select:()=>table==='profiles'?{eq:()=>({maybeSingle:async()=>({data:{id:'fixture-admin',email:'fixture@example.invalid',name:'Fixture Admin',role:'admin',active:true}})})}:{order:async()=>({data:[{id:'fixture-facility',name:'Fixture Facility',identifier:'fixture',active:true}]})}}),rpc:(name,args)=>{calls.push([name,args]);let result={data:null};if(name==='manager_session')result={data:{active:true,serverNow:Date.now(),idleExpiresAt:Date.now()+1800000,absoluteExpiresAt:Date.now()+43200000}};if(name==='inventory_counts')result={data:{}};if(name==='lock_inventory_reconciliation')result={data:report};if(name==='list_accounts')result={data:structuredClone(accounts)};if(name==='account_email_available')result={data:deliveryReady};if(name==='admin_action'){accounts.push({...args.p,account_id:'fixture-new-id',registered:false,setup_complete:false});result={data:{registered:false}}}if(name==='delete_team_account'){if(deleteFailure)result={data:null,error:{code:'P0001',message:'A setup email is still being processed.'}};else{const i=accounts.findIndex(a=>a.account_id===args.target_account_id);assert.ok(i>=0);accounts.splice(i,1);result={data:true}}}const p=Promise.resolve(result);p.abortSignal=()=>p;return p}};
  globalThis.accountFixtureClient=client;globalThis.fetch=async(url,options)=>{assert.match(url,/\/functions\/v1\/invite-employee$/);calls.push(['email',JSON.parse(options.body)]);return new Response(JSON.stringify(emailFailure?{error:'Fixture email failure'}:{ok:true,message:'Invitation sent.'}),{status:emailFailure?503:200,headers:{'Content-Type':'application/json'}})};
  const host=document.createElement('div');document.body.append(host);mounted=createRoot(host);await act(async()=>{mounted.render(React.createElement(Manager,{loginMessage:'Fixture headline'}));await new Promise(r=>setTimeout(r,20))});return {calls,accounts};
 }
 test('invite callback opens only the new-password form and password save completes setup',async()=>{
  const f=await mount({setup:true});assert.equal(f.calls[0][0],'setSession');assert.ok(button('Save password'));assert.equal(document.querySelector('input[type=email]'),null);assert.equal(win.location.hash,'');await type(document.querySelector('input[type=password]'),'fixture-password');await act(async()=>{document.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));await new Promise(r=>setTimeout(r,15))});assert.ok(f.calls.some(c=>c[0]==='updateUser'));assert.equal(button('Save password'),undefined);
 });
 test('saving a new employee sends one invitation only after access has been saved',async()=>{
  const f=await mount();await click(button('Add employee'));const fields=[...document.querySelectorAll('[role=dialog] input')];await type(fields.find(e=>e.type==='text'),'New Employee');await type(fields.find(e=>e.type==='email'),'new@example.invalid');assert.ok(button('Save & send invitation'));await act(async()=>{document.querySelector('[role=dialog] form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));await new Promise(r=>setTimeout(r,20))});assert.equal(f.calls.filter(c=>c[0]==='email').length,1);assert.ok(f.calls.findIndex(c=>c[0]==='admin_action')<f.calls.findIndex(c=>c[0]==='email'));assert.match(document.querySelector('[role=status]').textContent,/Invitation sent/);
 });
 test('email failure retains saved authorization, keeps resend available and does not announce success',async()=>{
  const f=await mount({emailFailure:true});await click(button('Add employee'));const fields=[...document.querySelectorAll('[role=dialog] input')];await type(fields.find(e=>e.type==='text'),'New Employee');await type(fields.find(e=>e.type==='email'),'new@example.invalid');await act(async()=>{document.querySelector('[role=dialog] form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));await new Promise(r=>setTimeout(r,20))});assert.ok(f.accounts.some(a=>a.email==='new@example.invalid'));assert.ok(document.querySelector('[role=dialog]'));assert.match(document.querySelector('[role=alert]').textContent,/Account access saved.*Fixture email failure/);assert.equal(document.querySelector('[role=status]'),null);assert.ok(button('Resend setup email'));
 });
 test('inactive employees cannot receive a setup email through the administrator UI',async()=>{const f=await mount();await click([...document.querySelectorAll('.admin-row')].find(b=>b.textContent.includes('Inactive Employee')));assert.equal(button('Resend setup email').disabled,true);assert.equal(f.calls.filter(c=>c[0]==='email').length,0)});
 test('confirmation rate limit is explicit in the login flow and never says email was sent',async()=>{await mount({anonymous:true});await type(document.querySelector('input[type=email]'),'fixture@example.invalid');await click(button('Resend confirmation email'));assert.match(document.querySelector('[role=alert]').textContent,/email service has reached its sending limit/i);assert.equal(document.querySelector('[role=status]'),null)});
 test('setup email stays disabled until delivery is configured',async()=>{
  const f=await mount({deliveryReady:false});
  await click(button('Add employee'));
  assert.ok(button('Save access'));
  assert.equal(button('Save & send invitation'),undefined);
  assert.match(document.querySelector('[role=dialog]').textContent,/Setup emails are unavailable/);
  assert.equal(f.calls.filter(c=>c[0]==='email').length,0);
 });
 test('deletion confirms the exact account and removes only the chosen entry',async()=>{
  const f=await mount();
  await click([...document.querySelectorAll('.admin-row')].find(b=>b.textContent.includes('Inactive Employee')));
  await click(button('Delete account…'));
  assert.match(document.querySelector('[role=dialog]').textContent,/inactive@example.invalid/);
  assert.equal(f.calls.filter(c=>c[0]==='delete_team_account').length,0);
  await click(button('Cancel'));
  assert.equal(f.accounts.length,1);
  await click(button('Delete account…'));
  await click(button('Permanently delete account'));
  assert.deepEqual(f.calls.filter(c=>c[0]==='delete_team_account'),[['delete_team_account',{target_account_id:'fixture-inactive-id'}]]);
  assert.equal(f.accounts.length,0);
  assert.equal(document.querySelector('[role=dialog]'),null);
  assert.match(document.querySelector('[role=status]').textContent,/Account deleted/);
 });
 test('a rejected deletion keeps the account and shows the error',async()=>{
  const f=await mount({deleteFailure:true});
  await click([...document.querySelectorAll('.admin-row')].find(b=>b.textContent.includes('Inactive Employee')));
  await click(button('Delete account…'));
  await click(button('Permanently delete account'));
  assert.equal(f.accounts.length,1);
  assert.ok(button('Permanently delete account'));
  assert.match(document.querySelector('[role=alert]').textContent,/still being processed/);
 });

 test('Administration renders reconciliation and filters retained records without another RPC',async()=>{
  const f=await mount();
  const panel=document.querySelector('section.reconciliation');
  assert.ok(panel);
  assert.deepEqual([...panel.querySelectorAll('.reconciliation-metrics dd')].map(node=>node.textContent),['2','1','1','1','1']);
  assert.match(panel.textContent,/Transition readiness · Review required/);
  assert.match(panel.textContent,/Latest recorded export evidence/);
  assert.ok(panel.querySelector('time[datetime="'+workerTime+'"]'));
  assert.ok(panel.querySelector('time[datetime="'+snapshotTime+'"]'));
  const finding=panel.querySelector('.reconciliation-filters select');
  await act(async()=>{finding.value='retained';finding.dispatchEvent(new Event('change',{bubbles:true}));});
  assert.deepEqual([...panel.querySelectorAll('.reconciliation-records strong')].map(node=>node.textContent),['FIXTURE2']);
  assert.match(panel.textContent,/Snapshot difference/);
  assert.equal(f.calls.filter(([name])=>name==='lock_inventory_reconciliation').length,1);
  await click(button('Refresh'));
  assert.equal(f.calls.filter(([name])=>name==='lock_inventory_reconciliation').length,2);
 });

}
