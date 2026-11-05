import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {verifyTwilio} from '@/lib/automation/twilio-verification.mjs';
export const maxDuration=60;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 return Response.json(await verifyTwilio(process.env),{headers:NO_STORE});
}
