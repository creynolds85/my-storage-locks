import {runtime,readiness} from './worker.mjs';
import {requestChallenge} from './tenant-security.mjs';
import {createTwilioSender} from './twilio.mjs';
export async function tenantDirectory(env=process.env){
 const rt=runtime(env);const info=await rt.store.call('tenant_directory');
 return {facilities:Array.isArray(info?.facilities)?info.facilities:[],testMode:!(info?.liveApproved&&env.LOCKS_LIVE_SMS_ENABLED==='true'&&readiness(env).ready&&createTwilioSender(env).ready()),challenge:requestChallenge(env.LOCKS_WORKER_TOKEN)};
}
