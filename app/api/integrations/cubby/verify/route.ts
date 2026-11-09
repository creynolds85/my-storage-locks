import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {runtime} from '@/lib/automation/worker.mjs';
import {verifyCubby,probeCubbyPolling} from '@/lib/automation/cubby-verification.mjs';
import {verifyCubbyConsent} from '@/lib/automation/cubby-consent-verification.mjs';
export const maxDuration=120;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{const rt=runtime();const body=await request.text();if(body.length>1000)return errorResponse('invalid_request',400);const input=body?JSON.parse(body):{};return Response.json(input.phase==='consent'?await verifyCubbyConsent(process.env,{store:rt.store}):input.phase==='poll'?await probeCubbyPolling(process.env,rt.store):await verifyCubby(process.env,{store:rt.store}),{headers:NO_STORE})}
 catch{return errorResponse('operational_verification_failed',503)}
}
