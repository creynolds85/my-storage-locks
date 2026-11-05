import {runtime} from '@/lib/automation/worker.mjs';
import {validTwilioRequest} from '@/lib/automation/twilio.mjs';
import {errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
export async function POST(request:Request){
 const raw=await request.text();if(Buffer.byteLength(raw)>16384)return errorResponse('payload_too_large',413);
 const entries=[...new URLSearchParams(raw)];if(new Set(entries.map(([k])=>k)).size!==entries.length)return errorResponse('duplicate_parameters',400);
 const params=Object.fromEntries(entries);if(!validTwilioRequest(request,params,process.env))return errorResponse('invalid_signature',403);
 const attemptId=new URL(request.url).searchParams.get('attempt');
 if(!attemptId||!/^[0-9a-f-]{36}$/i.test(attemptId)||!/^SM[0-9a-f]{32}$/i.test(params.MessageSid||''))return errorResponse('invalid_message_reference',422);
 try{await runtime().store.call('delivery_callback',{attemptId,providerSid:params.MessageSid,state:params.MessageStatus,errorCode:/^\d+$/.test(params.ErrorCode||'')?params.ErrorCode:null});return Response.json({ok:true},{headers:NO_STORE});}
 catch{console.error('automation_delivery_record_failed');return errorResponse('delivery_record_failed');}
}
