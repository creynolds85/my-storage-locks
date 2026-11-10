import twilio from 'twilio';
import {controlledClaimAllowed} from './controlled-test-guard.mjs';
import {CONTROLLED_PHONE} from './controlled-test-identity.mjs';
export function createTwilioSender(env,{clientFactory=twilio}={}){
 let controlledVerifiedAt=0;
 const ready=()=>['TWILIO_ACCOUNT_SID','TWILIO_API_KEY_SID','TWILIO_API_KEY_SECRET','TWILIO_MESSAGING_SERVICE_SID','TWILIO_AUTH_TOKEN'].every(k=>!!env[k])&&env.TWILIO_SENDER_VERIFIED==='true'&&env.TWILIO_BODY_REDACTION_VERIFIED==='true';
 async function submit({phone,body,attemptId},controlled=false){
  const client=clientFactory(env.TWILIO_API_KEY_SID,env.TWILIO_API_KEY_SECRET,{accountSid:env.TWILIO_ACCOUNT_SID,autoRetry:false,maxRetries:0,timeout:10000});
  try{
   const sent=await client.messages.create({to:phone,body,messagingServiceSid:env.TWILIO_MESSAGING_SERVICE_SID,statusCallback:'https://mystoragelocks.com/api/integrations/twilio/status?attempt='+encodeURIComponent(attemptId)+(controlled?'&controlled=1':''),contentRetention:'discard',validityPeriod:60});
   return {sid:sent.sid,state:sent.status||'accepted'};
  }catch(error){
   if(Number(error?.status)>=400&&Number(error?.status)<500)return {state:'failed',errorCode:/^\d+$/.test(String(error.code))?String(error.code):'provider_rejected'};
   return {state:'unknown',errorCode:'provider_outcome_unknown'};
  }
 }
 return {ready,
 async verifyControlledSender(){
  controlledVerifiedAt=0;
  try{
   const client=clientFactory(env.TWILIO_ACCOUNT_SID,env.TWILIO_AUTH_TOKEN,{autoRetry:false,maxRetries:0,timeout:10000});
   const service=client.messaging.v1.services(env.TWILIO_MESSAGING_SERVICE_SID);
   const [info,campaigns,pool]=await Promise.all([service.fetch(),service.usAppToPerson.list({limit:2}),service.phoneNumbers.list({limit:2})]);
   if(info.accountSid!==env.TWILIO_ACCOUNT_SID||info.friendlyName!=='My Storage Locks Access Notifications'||campaigns.length!==1||!['VERIFIED','APPROVED','TCR_APPROVED'].includes(campaigns[0].campaignStatus)||pool.length!==1)return false;
   const owned=await client.incomingPhoneNumbers(pool[0].sid).fetch();
   if(owned.accountSid!==env.TWILIO_ACCOUNT_SID||owned.phoneNumber!==pool[0].phoneNumber||(owned.capabilities?.sms!==true&&owned.capabilities?.SMS!==true))return false;
   controlledVerifiedAt=Date.now();return true;
  }catch{return false}
 },
 async send({phone,body,attemptId}){
  if(env.LOCKS_LIVE_SMS_ENABLED!=='true'||!ready())return {state:'failed',errorCode:'sms_configuration_missing'};
  return submit({phone,body,attemptId});
 },
 async sendControlledTest(claim){
  // Final provider boundary: no caller-selected recipient or alternate body.
  if(!controlledClaimAllowed(env,claim)||Date.now()-controlledVerifiedAt>30000||!controlledVerifiedAt)return {state:'failed',errorCode:'controlled_test_dispatch_blocked'};
  return submit({phone:CONTROLLED_PHONE,body:claim.body,attemptId:claim.attemptId},true);
 }};
}
export function validTwilioRequest(request,params,env){
 if(!env.TWILIO_AUTH_TOKEN||params.AccountSid!==env.TWILIO_ACCOUNT_SID)return false;
 const url=new URL(request.url);const expected='https://mystoragelocks.com'+url.pathname+url.search;
 return twilio.validateRequest(env.TWILIO_AUTH_TOKEN,request.headers.get('x-twilio-signature')||'',expected,params);
}
