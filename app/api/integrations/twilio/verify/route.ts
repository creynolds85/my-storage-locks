import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {verifyTwilio,verifyCampaignTemplates} from '@/lib/automation/twilio-verification.mjs';
export const maxDuration=60;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{const body=await request.text();if(body.length>1000)return errorResponse('invalid_request',400);const input=body?JSON.parse(body):{};
 return Response.json(input.phase==='campaign'?await verifyCampaignTemplates(process.env):await verifyTwilio(process.env),{headers:NO_STORE});
 }catch{return errorResponse('provider_verification_failed')}
}
