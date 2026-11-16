import {managerSessionAllowed,SESSION_EXPIRED_MESSAGE} from '@/lib/manager-session.mjs';
import {createClient} from '@supabase/supabase-js';
import {runtime} from '@/lib/automation/worker.mjs';
import {authorizeWorker,NO_STORE} from '@/lib/automation/security.mjs';
import {fetchWalkthroughSource} from '@/lib/walkthrough.mjs';
export const maxDuration=60;
export async function POST(request:Request){
 const privileged=authorizeWorker(request,process.env);
 try{
  const raw=await request.text();if(raw.length>200)return Response.json({error:'Invalid request.'},{status:400,headers:NO_STORE});
  const {facilityId}=JSON.parse(raw);if(!/^[a-f0-9-]{36}$/.test(facilityId||''))return Response.json({error:'Choose a facility.'},{status:400,headers:NO_STORE});
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL!,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!;
  if(!privileged){
   const auth=request.headers.get('authorization')||'';
   const client=createClient(url,key,{global:{headers:{Authorization:auth}},auth:{persistSession:false,autoRefreshToken:false}});
   const {data,error}=await client.auth.getUser(auth.replace(/^Bearer /,''));
   if(error||!data.user||!await managerSessionAllowed(client))return Response.json({error:SESSION_EXPIRED_MESSAGE},{status:401,headers:NO_STORE});
   const access=await client.rpc('walkthrough_access',{fid:facilityId});
   if(access.error)return Response.json({error:'This facility is not available to your account.'},{status:403,headers:NO_STORE});
   if(access.data?.refreshNeeded===false)return Response.json({ok:true,cached:true},{headers:NO_STORE});
  }
  const rt=runtime();const links=await rt.store.call('links');const link=links.find((l:any)=>l.facilityId===facilityId);
  if(!link||link.orgId!==process.env.CUBBY_ORGANIZATION_ID)throw Error('mapping_missing');
  const source=await fetchWalkthroughSource(rt.client,link);
  const result=await fetch(url+'/rest/v1/rpc/walkthrough_source_save',{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({token:process.env.LOCKS_WORKER_TOKEN,fid:facilityId,p:source}),cache:'no-store',signal:AbortSignal.timeout(10000)});
  if(!result.ok){let code='unknown';try{const failure=await result.json();if(/^[A-Z0-9]{5}$/.test(failure.code))code=failure.code}catch{}throw Error('source_save_failed_'+code);}
  return Response.json({ok:true,units:source.units.length,ordering:source.ordering},{headers:NO_STORE});
 }catch(error:any){const code=/^(walkthrough_|cubby_|source_save_failed_|mapping_)[a-zA-Z0-9_]+$/.test(error?.message||'')?error.message:'walkthrough_refresh_failed';console.error('walkthrough_refresh_failed',{code});return Response.json({error:'Current Cubby information could not be refreshed. Try again before confirming units.',...(privileged?{diagnostic:code}:{})},{status:503,headers:NO_STORE})}
}
