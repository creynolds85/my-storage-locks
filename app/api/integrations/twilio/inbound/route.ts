import {runtime} from '@/lib/automation/worker.mjs';
import {validTwilioRequest} from '@/lib/automation/twilio.mjs';
import {digest,normalizePhone} from '@/lib/automation/policy.mjs';
import {errorResponse} from '@/lib/automation/security.mjs';
export async function POST(request:Request){
 const raw=await request.text();if(Buffer.byteLength(raw)>16384)return errorResponse('payload_too_large',413);
 const entries=[...new URLSearchParams(raw)];if(new Set(entries.map(([k])=>k)).size!==entries.length)return errorResponse('duplicate_parameters',400);
 const params=Object.fromEntries(entries);if(!validTwilioRequest(request,params,process.env))return errorResponse('invalid_signature',403);
 const phone=normalizePhone(params.From);
 if(phone&&(params.OptOutType==='STOP'||/^(STOP|STOPALL|UNSUBSCRIBE|CANCEL|END|QUIT|REVOKE|OPTOUT)$/i.test((params.Body||'').trim()))){
  try{await runtime().store.call('suppress',{phoneHash:digest(phone),providerSid:params.MessageSid});}catch{console.error('automation_suppression_failed');return errorResponse('suppression_not_recorded');}
 }
 // START never silently reinstates access-message consent. No combination is returned in inbound replies.
 return new Response('<Response/>',{headers:{'Content-Type':'text/xml','Cache-Control':'no-store'}});
}
