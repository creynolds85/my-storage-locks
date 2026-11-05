import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {verifyWarehouse,WarehouseError} from '@/lib/automation/warehouse.mjs';
export const maxDuration=120;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{return Response.json(await verifyWarehouse(process.env),{headers:NO_STORE});}
 catch(error){return errorResponse(error instanceof WarehouseError?error.code:'warehouse_verification_failed',503);}
}
