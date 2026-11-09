// Change the version whenever the tenant-facing consent text changes.
export const REQUEST_CONSENT_VERSION='2026-11-08-request-1';
export const REQUEST_CONSENT_TEXT='I agree to receive one transactional text from My Storage Locks, operated by Storage Operations Specialists LLC on behalf of my selected facility, for this request. The message may contain a lock combination and access or lock-return instructions. One message per verified request. Message and data rates may apply. Reply STOP to opt out or HELP for help. Consent is optional and is not a condition of renting. This does not enroll me in recurring messages.';
export const SMS_HELP_TEXT='My Storage Locks: For help, select your facility at https://mystoragelocks.com/get-combination and choose Contact your facility. Msg & data rates may apply. Reply STOP to opt out.';
export function inboundReply(params,{liveEnabled=false}={}){
 // Advanced Opt-Out already replies when OptOutType is present. No access data is returned.
 if(!liveEnabled||params.OptOutType)return '<Response/>';
 if(/^(HELP|INFO|SUPPORT)$/i.test(String(params.Body||'').trim()))return '<Response><Message>'+SMS_HELP_TEXT.replace(/&/g,'&amp;')+'</Message></Response>';
 return '<Response/>';
}
