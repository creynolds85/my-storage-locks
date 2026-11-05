import {runtime,runTick} from '@/lib/automation/worker.mjs';
import {createTwilioSender} from '@/lib/automation/twilio.mjs';
import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
export const maxDuration=120;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{const result=await runTick(runtime(process.env,{sender:createTwilioSender(process.env)}));return Response.json(result,{headers:NO_STORE});}
 catch{console.error('automation_tick_failed');return errorResponse('automation_tick_failed');}
}
export const GET=POST;
