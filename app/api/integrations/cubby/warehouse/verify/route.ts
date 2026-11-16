import {runLockMirror,readLockSnapshot} from '@/lib/automation/lock-mirror.mjs';
import {runtime} from '@/lib/automation/worker.mjs';
import {authorizeWorker,errorResponse,NO_STORE} from '@/lib/automation/security.mjs';
import {verifyWarehouse,inspectWarehouseLockAssignments,WarehouseError} from '@/lib/automation/warehouse.mjs';
export const maxDuration=120;
export async function POST(request:Request){
 if(!authorizeWorker(request,process.env))return errorResponse('unauthorized',401);
 try{const raw=await request.text();if(raw.length>300)return errorResponse('invalid_request',400);const input=raw?JSON.parse(raw):{};if(input.phase==='lock_mirror_report')return Response.json(await runtime().store.call('lock_mirror_report'),{headers:NO_STORE});if(input.phase==='lock_mirror_run')return Response.json(await runLockMirror(runtime(),{force:true}),{headers:NO_STORE});if(input.phase==='lock_mirror_source'){const source=await readLockSnapshot(process.env);const records='records' in source?source.records:[];return Response.json({snapshotAt:source.snapshotAt,capabilities:source.capabilities,records:records.length,statuses:Object.fromEntries([...new Set(records.map(r=>r.status))].map(status=>[status,records.filter(r=>r.status===status).length])),combinationsReturned:false},{headers:NO_STORE});}return Response.json(input.phase==='lock_assignments'?await inspectWarehouseLockAssignments(process.env,input.sourceFacilityId):await verifyWarehouse(process.env),{headers:NO_STORE});}
 catch(error){return errorResponse(error instanceof WarehouseError?error.code:'warehouse_verification_failed',503);}
}
