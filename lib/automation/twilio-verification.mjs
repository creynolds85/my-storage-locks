import twilio from 'twilio';
import {renderMessage} from './policy.mjs';
import {SMS_HELP_TEXT} from './sms-disclosure.mjs';
const SERVICE_CALLBACK='https://mystoragelocks.com/api/integrations/twilio/inbound';
// Registration inspection only; never creates/updates a campaign or sends a message.
export async function verifyCampaignTemplates(env,{clientFactory=twilio}={}){
 if(!env.TWILIO_ACCOUNT_SID||!env.TWILIO_AUTH_TOKEN||!env.TWILIO_MESSAGING_SERVICE_SID)return {state:'configuration_required'};
 try{
  const client=clientFactory(env.TWILIO_ACCOUNT_SID,env.TWILIO_AUTH_TOKEN,{autoRetry:false,maxRetries:0,timeout:10000});
  const rows=await client.messaging.v1.services(env.TWILIO_MESSAGING_SERVICE_SID).usAppToPerson.list({limit:20});
  const example={facility:'[Facility Name]',unit:'[Unit]',serial:'[Serial]',combination:'[Combination]',returnInstructions:'[Approved Return Location]'};
  const allowed=new Set(['APPROVED','IN_PROGRESS','PENDING_REVIEW','TWILIO_APPROVED','TWILIO_REJECTED','TCR_PENDING','TCR_APPROVED','TCR_REJECTED','FAILED','REGISTERED','UNREGISTERED','SUSPENDED','VERIFIED','PENDING']);
  return {state:'checked',verifiedAt:new Date().toISOString(),campaignCount:rows.length,sampleLimited:rows.length===20,
   campaigns:rows.map(row=>({status:allowed.has(row.campaignStatus)?row.campaignStatus:'OTHER',
    accountNotificationUseCase:row.usAppToPersonUsecase==='ACCOUNT_NOTIFICATION',embeddedLinks:row.hasEmbeddedLinks,
    sampleCount:row.messageSamples?.length||0,
    productionOverlockExactSample:(row.messageSamples||[]).includes(renderMessage('overlock_clearance',example)),
    productionRentalExactSample:(row.messageSamples||[]).includes(renderMessage('new_rental',example)),
    sampleChecks:(row.messageSamples||[]).map(text=>({programIdentified:/My Storage Locks/i.test(text),
     overlockPurpose:/overlock (removal|clear)/i.test(text),rentalPurpose:/rental|move[ -]?in|rented unit/i.test(text),
     stopPresent:/\bSTOP\b/.test(text),helpPresent:/\bHELP\b/.test(text),returnInstructionsPresent:/return.*lock/i.test(text)})),
    optOutDescriptionPresent:!!row.optOutMessage,helpDescriptionPresent:!!row.helpMessage,
    helpMatchesProduction:row.helpMessage===SMS_HELP_TEXT,registeredHelpContainsUrl:/https?:\/\//i.test(row.helpMessage||''),
    productionHelpContainsUrl:/https?:\/\//i.test(SMS_HELP_TEXT),
    privacyUrlInFlow:(row.messageFlow||'').includes('https://mystoragelocks.com/privacy'),
    termsUrlInFlow:(row.messageFlow||'').includes('https://mystoragelocks.com/terms')})),
   smsSubmitted:0,campaignWrites:0,liveSendingEnabled:env.LOCKS_LIVE_SMS_ENABLED==='true'};
 }catch(error){return {state:Number(error?.status)===403?'permission_required':'campaign_inspection_unavailable',smsSubmitted:0,campaignWrites:0}}
}
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
