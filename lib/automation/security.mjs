import {createHmac,timingSafeEqual} from 'node:crypto';
export function secretEqual(a,b){if(!a||!b)return false;const left=Buffer.from(a),right=Buffer.from(b);return left.length===right.length&&timingSafeEqual(left,right)}
export function authorizeWorker(request,env){return secretEqual(request.headers.get('authorization'),'Bearer '+(env.LOCKS_CRON_SECRET||''))&&!!env.LOCKS_CRON_SECRET}
export function authorizeCubbyWebhook(request,raw,env,now=Date.now()){
 if(env.CUBBY_WEBHOOK_AUTH_CONFIRMED!=='true'||!env.CUBBY_WEBHOOK_SECRET)return false;
 if(env.CUBBY_WEBHOOK_AUTH_MODE==='bearer')return secretEqual(request.headers.get('authorization'),'Bearer '+env.CUBBY_WEBHOOK_SECRET);
 if(env.CUBBY_WEBHOOK_AUTH_MODE==='hmac-sha256'){
  // This contract must match the actual provider/approved authenticated relay; it is not assumed from public docs.
  const stamp=request.headers.get(env.CUBBY_WEBHOOK_TIMESTAMP_HEADER||'x-cubby-timestamp');
  const signature=request.headers.get(env.CUBBY_WEBHOOK_SIGNATURE_HEADER||'x-cubby-signature');
  const timestamp=Number(stamp)*1000;
  if(!Number.isFinite(timestamp)||Math.abs(now-timestamp)>300000)return false;
  const expected=createHmac('sha256',env.CUBBY_WEBHOOK_SECRET).update(stamp+'.'+raw).digest('hex');
  return secretEqual(signature?.replace(/^sha256=/,''),expected);
 }
 return false;
}
export const NO_STORE={'Cache-Control':'no-store','Content-Type':'application/json'};
export function errorResponse(code,status=503){return Response.json({ok:false,code},{status,headers:NO_STORE})}
