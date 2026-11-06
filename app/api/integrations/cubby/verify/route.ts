import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {runtime} from '@/lib/automation/worker.mjs';
import {verifyCubby} from '@/lib/automation/cubby-verification.mjs';
export const maxDuration=120;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{const rt=runtime();return Response.json(await verifyCubby(process.env,{store:rt.store}),{headers:NO_STORE})}
 catch{return errorResponse('operational_verification_failed',503)}
}
