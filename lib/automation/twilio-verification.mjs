import twilio from 'twilio';
const SERVICE_CALLBACK='https://mystoragelocks.com/api/integrations/twilio/inbound';
async function inspectSenderConfiguration(admin,serviceSid,pool){
 const permitted=new Set(['APPROVED','IN_PROGRESS','PENDING_REVIEW','TWILIO_APPROVED','TWILIO_REJECTED','TCR_PENDING','TCR_APPROVED','TCR_REJECTED','VERIFIED','REJECTED','PENDING','FAILED','REGISTERED','UNREGISTERED','SUSPENDED']);
 const statuses=rows=>rows.reduce((counts,row)=>{const raw=String(row.campaignStatus||row.status||'').toUpperCase(),key=permitted.has(raw)?raw:'OTHER';counts[key]=(counts[key]||0)+1;return counts},{});
 async function inspect(read,summarize){try{const rows=await read();return {state:'checked',...summarize(rows),sampleLimited:rows.length===100}}catch(error){return {state:Number(error?.status)===403?'permission_required':'unavailable'}}}
 const [ownedNumbers,a2pCampaigns,tollFreeVerifications]=await Promise.all([
  inspect(()=>admin.incomingPhoneNumbers.list({limit:100}),rows=>{const sms=rows.filter(n=>n.capabilities?.sms===true||n.capabilities?.SMS===true);return {total:rows.length,smsCapable:sms.length,unattachedSmsCapable:sms.filter(n=>!pool.some(p=>p.sid===n.sid)).length}}),
  inspect(()=>admin.messaging.v1.services(serviceSid).usAppToPerson.list({limit:100}),rows=>({count:rows.length,statuses:statuses(rows)})),
  inspect(()=>admin.messaging.v1.tollfreeVerifications.list({limit:100}),rows=>({count:rows.length,statuses:statuses(rows)}))
 ]);
 // No phone numbers, registration identities, message bodies or provider errors leave this verifier.
 return {ownedNumbers,a2pCampaigns,tollFreeVerifications};
}
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
  const checks=await inspectSenderConfiguration(admin,env.TWILIO_MESSAGING_SERVICE_SID,numbers);
  return {state:'connected',verifiedAt:new Date().toISOString(),accountActive:account.status==='active',apiKeyAuthenticationVerified:true,callbackTokenAuthenticationVerified:true,serviceName:service.friendlyName,inboundCallbackCorrect:service.inboundRequestUrl===SERVICE_CALLBACK&&service.inboundMethod==='POST',validitySeconds:service.validityPeriod,smartEncoding:service.smartEncoding,senderCount:numbers.length,senderRegistrationVerified:false,senderConfiguration:checks,deliveryCallbackMode:'per-message attempt ID; real provider delivery test still required',sendTestPerformed:false,liveSendingEnabled:env.LOCKS_LIVE_SMS_ENABLED==='true'};
 }catch(error){const status=Number(error?.status);return {state:status===401?'credential_authentication_failed':status===403?'credential_permission_denied':'provider_verification_failed',sendTestPerformed:false,liveSendingEnabled:false};}
}
