import twilio from 'twilio';
export function createTwilioSender(env){
 const ready=()=>['TWILIO_ACCOUNT_SID','TWILIO_API_KEY_SID','TWILIO_API_KEY_SECRET','TWILIO_MESSAGING_SERVICE_SID','TWILIO_AUTH_TOKEN'].every(k=>!!env[k])&&env.TWILIO_SENDER_VERIFIED==='true'&&env.TWILIO_BODY_REDACTION_VERIFIED==='true';
 return {ready,async send({phone,body,attemptId}){
  if(!ready())return {state:'failed',errorCode:'sms_configuration_missing'};
  const client=twilio(env.TWILIO_API_KEY_SID,env.TWILIO_API_KEY_SECRET,{accountSid:env.TWILIO_ACCOUNT_SID,autoRetry:false,maxRetries:0,timeout:10000});
  try{
   const sent=await client.messages.create({to:phone,body,messagingServiceSid:env.TWILIO_MESSAGING_SERVICE_SID,statusCallback:'https://mystoragelocks.com/api/integrations/twilio/status?attempt='+encodeURIComponent(attemptId),contentRetention:'discard',validityPeriod:60});
   return {sid:sent.sid,state:sent.status||'accepted'};
  }catch(error){
   if(Number(error?.status)>=400&&Number(error?.status)<500)return {state:'failed',errorCode:/^\d+$/.test(String(error.code))?String(error.code):'provider_rejected'};
   return {state:'unknown',errorCode:'provider_outcome_unknown'};
  }
 }};
}
export function validTwilioRequest(request,params,env){
 if(!env.TWILIO_AUTH_TOKEN||params.AccountSid!==env.TWILIO_ACCOUNT_SID)return false;
 const url=new URL(request.url);const expected='https://mystoragelocks.com'+url.pathname+url.search;
 return twilio.validateRequest(env.TWILIO_AUTH_TOKEN,request.headers.get('x-twilio-signature')||'',expected,params);
}
