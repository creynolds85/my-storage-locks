import {after} from 'next/server';
import {runtime,drainInbox,drainOutbox} from '@/lib/automation/worker.mjs';
import {createTwilioSender} from '@/lib/automation/twilio.mjs';
import {authorizeCubbyWebhook,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {eventReference,digest} from '@/lib/automation/policy.mjs';
export const maxDuration=120;
const types:Record<string,string>={'move-in':'move_in','overlock-clearance':'overlock_clearance','lease-changed':'lease_changed','document-completed':'document_completed','auction-changed':'auction_changed'};
export async function POST(request:Request,context:{params:Promise<{event:string}>}){
 const {event}=await context.params;const eventType=types[event];if(!eventType)return errorResponse('unsupported_event',404);
 if(Number(request.headers.get('content-length')||0)>65536)return errorResponse('payload_too_large',413);
 const raw=await request.text();if(Buffer.byteLength(raw)>65536)return errorResponse('payload_too_large',413);
 if(!authorizeCubbyWebhook(request,raw,process.env))return errorResponse('webhook_authentication_required',401);
 let payload;try{payload=JSON.parse(raw)}catch{return errorResponse('invalid_json',400)}
 const reference=eventReference(payload);if(!reference)return errorResponse('event_identity_missing',422);
 const occurredAt=payload.occurredAt||payload.lease?.updatedAt;
 if(typeof occurredAt!=='string'||!/(Z|[+-]\d\d:\d\d)$/.test(occurredAt)||!Number.isFinite(Date.parse(occurredAt))||Date.parse(occurredAt)>Date.now()+5000)return errorResponse('event_timestamp_unverified',422);
 try{
  const rt=runtime(process.env,{sender:createTwilioSender(process.env)});
  const saved=await rt.store.call('inbox_accept',{eventType,reference,occurredAt,key:digest([eventType,reference.leaseId,occurredAt].join(':'))});
  if(saved?.id)after(async()=>{try{const processed=await drainInbox(rt,{id:saved.id,limit:1});for(const id of processed.notificationIds||[])await drainOutbox(rt,{id,limit:1})}catch{console.error('automation_event_processing_failed')}});
  return Response.json({accepted:true,duplicate:!saved?.id},{status:200,headers:NO_STORE});
 }catch{console.error('automation_event_accept_failed');return errorResponse('durable_event_accept_failed');}
}
