export function createAutomationStore({url,key,workerToken,fetcher=fetch}={}){
 if(!url||!key||!workerToken)throw new Error('worker_configuration_missing');
 return {async call(operation,p={}){
  let response;try{response=await fetcher(url+'/rest/v1/rpc/automation_worker',{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({token:workerToken,operation,p}),signal:AbortSignal.timeout(10000),cache:'no-store',redirect:'error'})}catch{throw new Error('automation_store_unreachable')}
  if(!response.ok)throw new Error('automation_store_rejected');
  return response.json();
 }};
}
