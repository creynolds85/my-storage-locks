export const SESSION_EXPIRED_MESSAGE='Your session has expired. Please sign in again.';
export const MEANINGFUL_EVENTS=['pointerdown','keydown','wheel','touchstart'];
export async function managerSessionAllowed(client){const {data,error}=await client.rpc('manager_session',{activity:false});return !error&&data?.active===true}

// Deadlines come from the server. Timers and visibility checks only READ them.
export function createManagerSessionMonitor({verify,onExpired,initial,now=()=>performance.now(),setTimer=setTimeout,clearTimer=clearTimeout}){
 let stopped=false,timer=null,poll=null,idle=0,absolute=Infinity,lastSent=-Infinity,inFlight=false;
 function stop(){stopped=true;clearTimer(timer);clearTimer(poll)}
 function expire(){if(stopped)return;stop();onExpired()}
 function schedule(){clearTimer(timer);timer=setTimer(()=>{if(now()>=absolute)expire();else void check(false)},Math.max(0,Math.min(idle,absolute)-now()))}
 function apply(data){if(!data?.active||![data.serverNow,data.idleExpiresAt,data.absoluteExpiresAt].every(Number.isFinite)){expire();return false}idle=now()+Math.max(0,data.idleExpiresAt-data.serverNow);absolute=Math.min(absolute,now()+Math.max(0,data.absoluteExpiresAt-data.serverNow));if(now()>=idle||now()>=absolute){expire();return false}schedule();return true}
 async function check(activity=false){if(stopped)return false;if(now()>=absolute){expire();return false}try{let timeout;try{const result=await Promise.race([verify(activity),new Promise((_,reject)=>{timeout=setTimer(()=>reject(Error('session_check_timeout')),5000)})]);return !stopped&&apply(result)}finally{clearTimer(timeout)}}catch{if(now()>=idle||now()>=absolute)expire();return false}}
 async function activity(event){if(stopped||event?.isTrusted!==true||now()-lastSent<5000||inFlight)return;if(now()>=idle||now()>=absolute){await check(false);return}lastSent=now();inFlight=true;try{await check(true)}finally{inFlight=false}}
 async function pollStatus(){await check(false);if(!stopped)poll=setTimer(pollStatus,60000)}
 apply(initial);if(!stopped)poll=setTimer(pollStatus,60000);
 return {stop,activity,check:()=>check(false)};
}
export function attachManagerActivity(monitor,{document,window}){
 const activity=event=>{if(document.visibilityState==='visible')void monitor.activity(event)};
 const resume=()=>{if(document.visibilityState==='visible')void monitor.check()};
 for(const event of MEANINGFUL_EVENTS)document.addEventListener(event,activity,{passive:true,capture:true});
 document.addEventListener('visibilitychange',resume);window.addEventListener('pageshow',resume);
 return ()=>{for(const event of MEANINGFUL_EVENTS)document.removeEventListener(event,activity,true);document.removeEventListener('visibilitychange',resume);window.removeEventListener('pageshow',resume);monitor.stop()};
}
export function clearManagerAuthStorage(url,document,storage){
 const prefix='sb-'+new URL(url).hostname.split('.')[0]+'-auth-token';
 for(const cookie of document.cookie.split(';')){const name=cookie.split('=')[0].trim();if(name.startsWith(prefix))document.cookie=name+'=; Path=/; Max-Age=0; SameSite=Lax';}
 try{for(let i=storage.length-1;i>=0;i--){const key=storage.key(i);if(key?.startsWith(prefix)||key?.startsWith('lock-manager-facility-'))storage.removeItem(key)}}catch{}
}
