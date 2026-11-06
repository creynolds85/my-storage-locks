import {after} from 'next/server';
import {randomInt} from 'node:crypto';
import {runtime,drainInbox,drainOutbox} from '@/lib/automation/worker.mjs';
import {createTwilioSender} from '@/lib/automation/twilio.mjs';
import {tenantInput,TENANT_RESPONSE} from '@/lib/automation/tenant-security.mjs';
export const maxDuration=120;
const headers={'Cache-Control':'private, no-store','Content-Type':'application/json','X-Robots-Tag':'noindex, nofollow'};
export async function POST(request:Request){
 const began=Date.now();
 try{
  const origin=request.headers.get('origin'),site=request.headers.get('sec-fetch-site');
  if(origin!==new URL(request.url).origin||site==='cross-site'||!request.headers.get('content-type')?.startsWith('application/json')||Number(request.headers.get('content-length')||0)>2500)throw Error('invalid_request');
  const raw=await request.text();if(Buffer.byteLength(raw)>2500)throw Error('invalid_request');
  const data=tenantInput(JSON.parse(raw),{secret:process.env.LOCKS_WORKER_TOKEN,ip:(request.headers.get('x-vercel-forwarded-for')||request.headers.get('x-forwarded-for')||'').split(',')[0].trim()});
  if(data){
   const rt=runtime(process.env,{sender:createTwilioSender(process.env)});
   const accepted=await rt.store.call('tenant_intake',data);
   if(accepted?.eventId)after(async()=>{try{const result=await drainInbox(rt,{id:accepted.eventId,limit:1});for(const id of result.notificationIds||[])await drainOutbox(rt,{id,limit:1})}catch{console.error('tenant_request_processing_failed')}});
  }
 }catch{ /* Identical response for invalid, unknown, suppressed, limited and unavailable requests. No input or source data is logged. */ }
 const wait=250+randomInt(101)-(Date.now()-began);if(wait>0)await new Promise(resolve=>setTimeout(resolve,wait));
 return Response.json({message:TENANT_RESPONSE},{status:202,headers});
}
