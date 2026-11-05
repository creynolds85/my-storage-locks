import twilio from 'twilio';
const SERVICE_CALLBACK='https://mystoragelocks.com/api/integrations/twilio/inbound';
export async function verifyTwilio(env,{clientFactory=twilio}={}){
 const needed=['TWILIO_ACCOUNT_SID','TWILIO_API_KEY_SID','TWILIO_API_KEY_SECRET','TWILIO_AUTH_TOKEN','TWILIO_MESSAGING_SERVICE_SID'];
 const missing=needed.filter(k=>!env[k]);if(missing.length)return {state:'configuration_required',missing,sendTestPerformed:false,liveSendingEnabled:false};
 const options={accountSid:env.TWILIO_ACCOUNT_SID,autoRetry:false,maxRetries:0,timeout:10000};
 try{
  const sender=clientFactory(env.TWILIO_API_KEY_SID,env.TWILIO_API_KEY_SECRET,options);
  const admin=clientFactory(env.TWILIO_ACCOUNT_SID,env.TWILIO_AUTH_TOKEN,options);
  // These are read-only provider requests. No message body or recipient is returned or logged.
  const [account,,service,numbers]=await Promise.all([admin.api.accounts(env.TWILIO_ACCOUNT_SID).fetch(),sender.messages.list({limit:1}),admin.messaging.v1.services(env.TWILIO_MESSAGING_SERVICE_SID).fetch(),admin.messaging.v1.services(env.TWILIO_MESSAGING_SERVICE_SID).phoneNumbers.list({limit:100})]);
  if(account.sid!==env.TWILIO_ACCOUNT_SID||service.accountSid!==env.TWILIO_ACCOUNT_SID||service.sid!==env.TWILIO_MESSAGING_SERVICE_SID)return {state:'account_or_service_mismatch',sendTestPerformed:false,liveSendingEnabled:false};
  return {state:'connected',verifiedAt:new Date().toISOString(),accountActive:account.status==='active',apiKeyAuthenticationVerified:true,callbackTokenAuthenticationVerified:true,serviceName:service.friendlyName,inboundCallbackCorrect:service.inboundRequestUrl===SERVICE_CALLBACK&&service.inboundMethod==='POST',validitySeconds:service.validityPeriod,smartEncoding:service.smartEncoding,senderCount:numbers.length,senderRegistrationVerified:false,deliveryCallbackMode:'per-message attempt ID; real provider delivery test still required',sendTestPerformed:false,liveSendingEnabled:env.LOCKS_LIVE_SMS_ENABLED==='true'};
 }catch(error){const status=Number(error?.status);return {state:status===401?'credential_authentication_failed':status===403?'credential_permission_denied':'provider_verification_failed',sendTestPerformed:false,liveSendingEnabled:false};}
}
