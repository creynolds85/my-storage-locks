import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {verifyWarehouse,inspectWarehouseLockAssignments,WarehouseError} from '@/lib/automation/warehouse.mjs';
export const maxDuration=120;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{const raw=await request.text();if(raw.length>300)return errorResponse('invalid_request',400);const input=raw?JSON.parse(raw):{};return Response.json(input.phase==='lock_assignments'?await inspectWarehouseLockAssignments(process.env,input.sourceFacilityId):await verifyWarehouse(process.env),{headers:NO_STORE});}
 catch(error){return errorResponse(error instanceof WarehouseError?error.code:'warehouse_verification_failed',503);}
}
