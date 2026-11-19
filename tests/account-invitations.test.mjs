import test from 'node:test';import assert from 'node:assert/strict';
import {createInvitationHandler} from '../supabase/functions/invite-employee/handler.mjs';
import {hasManagerTokens,consumeManagerAuthCallback,accountEmailError} from '../lib/manager-auth.mjs';
function fixture({user=true,claimError=null,kind='invite',mailError=null,finishError=null,throwMail=false}={}){
 const calls=[];const claim={attemptId:'fixture-attempt',email:'authorized@example.invalid',kind};
 const caller={auth:{getUser:async()=>({data:{user:user?{id:'fixture-admin'}:null},error:user?null:{code:'invalid_jwt'}})},rpc:async(name,args)=>{calls.push([name,args]);return name==='account_invitation_claim'?{data:claim,error:claimError}:{data:true,error:finishError}}};
 const mail=async(...args)=>{calls.push(['mail',...args]);if(throwMail)throw Error('PRIVATE PROVIDER DETAIL');return {data:{user:{id:'fixture-user'}},error:mailError}};
 const handler=createInvitationHandler({callerFor:()=>caller,mailerFor:()=>{calls.push(['privileged-client']);return {auth:{admin:{inviteUserByEmail:mail},resend:mail,resetPasswordForEmail:mail}}}});
 const request=(body={email:'authorized@example.invalid'},headers={authorization:'Bearer fixture-user-jwt',origin:'https://mystoragelocks.com'})=>new Request('https://fixture.invalid',{method:'POST',headers,body:JSON.stringify(body)});
 return {calls,handler,request};
}
test('anonymous, invalid sessions and rejected origins never create a privileged email client',async()=>{
 for(const setup of [{headers:{}},{user:false},{headers:{authorization:'Bearer fixture',origin:'https://attacker.invalid'}}]){const f=fixture(setup);const r=await f.handler(f.request(undefined,setup.headers));assert.ok([401,403].includes(r.status));assert.equal(f.calls.some(c=>c[0]==='privileged-client'),false)}
});
test('non-admin, inactive account, disabled delivery and duplicate claims cannot send mail',async()=>{
 for(const [code,status] of [['42501',403],['P0001',503],['P0002',429]]){const f=fixture({claimError:{code}});const r=await f.handler(f.request());assert.equal(r.status,status);assert.equal(f.calls.some(c=>c[0]==='mail'||c[0]==='privileged-client'),false)}
});
test('rejects malformed recipients and oversized payloads without querying account access',async()=>{
 for(const body of [{email:'bad'}, {email:'x'.repeat(500)}]){const f=fixture();assert.equal((await f.handler(f.request(body))).status,400);assert.equal(f.calls.length,0)}
});
test('new approved recipient receives an invite with a fixed production password-setup destination',async()=>{
 const f=fixture(),r=await f.handler(f.request());assert.equal(r.status,200);assert.equal((await r.json()).kind,'invite');const mail=f.calls.find(c=>c[0]==='mail');assert.equal(mail[1],'authorized@example.invalid');assert.equal(mail[2].redirectTo,'https://mystoragelocks.com/login?setup=1');assert.equal(f.calls.at(-1)[1].p.state,'sent');
});
test('pending self-signups resend confirmation; established accounts receive recovery links',async()=>{
 for(const kind of ['confirmation','recovery']){const f=fixture({kind});const r=await f.handler(f.request());assert.equal(r.status,200);assert.equal((await r.json()).kind,kind);const mail=f.calls.find(c=>c[0]==='mail');if(kind==='confirmation'){assert.equal(mail[1].type,'signup');assert.equal(mail[1].email,'authorized@example.invalid')}else assert.equal(mail[2].redirectTo,'https://mystoragelocks.com/login?setup=1')}
});
test('provider rejection records a failure and never reports an invitation sent or exposes raw details',async()=>{
 const f=fixture({mailError:{code:'over_email_send_rate_limit',status:429,message:'PRIVATE PROVIDER DETAIL'}}),r=await f.handler(f.request());assert.equal(r.status,429);const result=await r.text();assert.match(result,/sending limit/);assert.doesNotMatch(result,/PRIVATE/);assert.equal(f.calls.at(-1)[1].p.state,'failed');
});
test('network ambiguity and audit failure do not invite automatic duplicate sends',async()=>{
 for(const opts of [{throwMail:true},{finishError:{message:'fixture'}}]){const f=fixture(opts),r=await f.handler(f.request());assert.equal(r.status,503);assert.match((await r.json()).error,/uncertain/);assert.equal(f.calls.filter(c=>c[0]==='mail').length,1)}
});
test('ordinary signups keep PKCE detection; invite tokens are consumed and removed before any asynchronous work',async()=>{
 assert.equal(hasManagerTokens(null),false);assert.equal(hasManagerTokens('https://fixture.invalid/login?code=fixture'),false);
 const url='https://fixture.invalid/login?setup=1#access_token=fixture-access&refresh_token=fixture-refresh&type=invite';assert.equal(hasManagerTokens(url),true);const calls=[];
 const client={auth:{setSession:async tokens=>{calls.push(['session',tokens]);return {error:null}}}};
 assert.deepEqual(await consumeManagerAuthCallback(client,url,p=>calls.push(['clean',p])),{handled:true,setup:true});assert.deepEqual(calls[0],['clean','/login']);assert.deepEqual(calls[1],['session',{access_token:'fixture-access',refresh_token:'fixture-refresh'}]);
 assert.deepEqual(await consumeManagerAuthCallback(client,'https://fixture.invalid/login?code=fixture',()=>assert.fail('PKCE left to SDK')),{handled:false,setup:false});
});
test('failed invite validation never claims password setup succeeded and still removes callback secrets',async()=>{
 let clean=false;await assert.rejects(()=>consumeManagerAuthCallback({auth:{setSession:async()=>({error:Error('expired fixture')})}},'https://fixture.invalid/login#access_token=fixture&refresh_token=fixture&type=recovery',()=>{clean=true}),/expired fixture/);assert.equal(clean,true);assert.match(accountEmailError({code:'email_not_confirmed'}),/Confirm your email/);assert.match(accountEmailError({code:'over_email_send_rate_limit'}),/sending limit/);
});

test('expired emailed links show a useful error and discard obsolete callback parameters',async()=>{
 let cleaned;await assert.rejects(()=>consumeManagerAuthCallback({},'https://fixture.invalid/login#error=access_denied&error_code=otp_expired',p=>{cleaned=p}),e=>e.code==='otp_expired');assert.equal(cleaned,'/login');
});
