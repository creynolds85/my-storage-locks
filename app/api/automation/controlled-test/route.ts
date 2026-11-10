import {runtime} from '@/lib/automation/worker.mjs';
import {createTwilioSender} from '@/lib/automation/twilio.mjs';
import {controlledTest} from '@/lib/automation/controlled-test.mjs';
import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
export const maxDuration=60;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{
  const raw=await request.text();if(raw.length>200)return errorResponse('invalid_request',400);
  const input=raw?JSON.parse(raw):{};
  if(Object.keys(input).some(k=>k!=='operation')||!['inspect','dispatch'].includes(input.operation||'inspect'))return errorResponse('invalid_request',400);
  return Response.json(await controlledTest(runtime(process.env,{sender:createTwilioSender(process.env)}),{dispatch:input.operation==='dispatch'}),{headers:NO_STORE});
 }catch{return errorResponse('controlled_test_unavailable')}
}
