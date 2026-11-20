const ORIGIN='https://mystoragelocks.com';
const REDIRECT=ORIGIN+'/login?setup=1';
const SAFE_CODES=new Set(['over_email_send_rate_limit','over_email_send_rate_limit_user','email_address_not_authorized','email_exists']);
const errorText=code=>code==='over_email_send_rate_limit'?'The email service has reached its sending limit. Access is saved; contact an administrator.':code==='over_email_send_rate_limit_user'?'Please wait a minute before requesting another setup email.':code==='email_address_not_authorized'?'Account email delivery is not configured for this address. Contact an administrator.':'The email could not be sent. Access is saved. Please try Resend setup email later.';
export function createInvitationHandler({callerFor,mailerFor}){
 return async request=>{
  const origin=request.headers.get('origin');
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin',...(origin===ORIGIN?{'Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'}:{})};
  const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
  if(origin&&origin!==ORIGIN)return reply({error:'This origin is not allowed.'},403);
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(request.method!=='POST')return reply({error:'Use POST.'},405);
  const authorization=request.headers.get('authorization')||'';
  if(!/^Bearer \S+$/.test(authorization))return reply({error:'Sign in as an administrator.'},401);
  let caller,claim;
  try{
   const raw=await request.text();if(raw.length>400)return reply({error:'Invalid request.'},400);
   let input;try{input=JSON.parse(raw)}catch{return reply({error:'Invalid request.'},400)}
   if(typeof input.email!=='string'||input.email.length>254||!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(input.email))return reply({error:'Enter an authorized email address.'},400);
   caller=callerFor(authorization);
   const user=await caller.auth.getUser(authorization.slice(7));
   if(user.error||!user.data?.user)return reply({error:'Sign in as an administrator.'},401);
   const result=await caller.rpc('account_invitation_claim',{recipient:input.email.trim().toLowerCase()});
   if(result.error){const code=result.error.code;return reply({error:code==='P0001'?'Account email delivery is not configured yet. Access is saved.':code==='P0002'?'Please wait before requesting another setup email.':'Only administrators can email active authorized accounts.'},code==='P0001'?503:code==='P0002'?429:403)}
   claim=result.data;
   if(!claim?.attemptId||!claim.email||!['invite','confirmation','recovery'].includes(claim.kind))throw Error('invalid_claim');
   // No privileged client or email operation exists before the caller/session gate.
   const mailer=mailerFor();
   let outcome;
   try{
    outcome=claim.kind==='invite'?await mailer.auth.admin.inviteUserByEmail(claim.email,{redirectTo:REDIRECT}):claim.kind==='confirmation'?await mailer.auth.resend({type:'signup',email:claim.email,options:{emailRedirectTo:ORIGIN+'/login'}}):await mailer.auth.resetPasswordForEmail(claim.email,{redirectTo:REDIRECT});
   }catch{outcome={error:{code:'email_outcome_unknown'}}}
   const error=outcome?.error,unknown=error?.code==='email_outcome_unknown'||(error&&(!error.status||error.status>=500));
   const state=error?(unknown?'unknown':'failed'):'sent',code=unknown?'email_outcome_unknown':SAFE_CODES.has(error?.code)?error.code:'email_send_failed';
   const finish=await caller.rpc('account_invitation_finish',{p:{attemptId:claim.attemptId,state,...(error?{code}:{})}});
   if(finish.error||unknown)return reply({error:'The email outcome is uncertain. Check the recipient’s inbox before retrying in five minutes.'},503);
   if(error)return reply({error:errorText(code)},error.status===429?429:503);
   return reply({ok:true,kind:claim.kind,message:claim.kind==='confirmation'?'Confirmation email sent.':claim.kind==='recovery'?'Password setup email sent.':'Invitation sent.'});
  }catch{
   if(caller&&claim?.attemptId)try{await caller.rpc('account_invitation_finish',{p:{attemptId:claim.attemptId,state:'unknown',code:'email_outcome_unknown'}})}catch{}
   return reply({error:'Unable to complete the email request. Access is saved. Check the inbox before retrying.'},503);
  }
 };
}
