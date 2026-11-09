import {createCubbyClient,IntegrationError} from './cubby.mjs';
const keys=value=>value&&typeof value==='object'&&!Array.isArray(value)?Object.keys(value).filter(k=>/^[a-zA-Z][a-zA-Z0-9_]{0,60}$/.test(k)).sort():[];
/** Read consent metadata only. Never return customer identifiers, contacts or preferences per person. */
/** @param {any} env @param {{store?:any,client?:any}} options */
export async function verifyCubbyConsent(env,{store,client=createCubbyClient({apiKey:env.CUBBY_API_KEY,limit:30})}={}){
 const links=(await store.call('links')).filter(l=>l.orgId===env.CUBBY_ORGANIZATION_ID);
 const root=new Set(),preferences=new Set(),sms=new Set(),proofPaths=new Set();
 let examined=0,facilities=0,limited=0,suppressed=0,unsuppressed=0,unknown=0;
 const failures=[];
 for(const link of links){
  try{
   const data=await client.search('customers/search',{facilityId:link.sourceFacilityId});
   if(!Array.isArray(data.customers))throw new IntegrationError('cubby_collections_missing');
   facilities++;if(data.customers.length>=1000)limited++;
   for(const c of data.customers){
    examined++;keys(c).forEach(k=>root.add(k));
    keys(c.communicationPreferences).forEach(k=>preferences.add(k));
    keys(c.communicationPreferences?.sms).forEach(k=>sms.add(k));
    const flag=c.communicationPreferences?.sms?.suppressed;
    if(flag===true)suppressed++;else if(flag===false)unsuppressed++;else unknown++;
    function visit(v,path,depth){if(depth>3)return;for(const k of keys(v)){const next=path?path+'.'+k:k;if(/consent|opt.?in|permission|evidence|agreement|signature/i.test(k))proofPaths.add(next);if(v[k]&&typeof v[k]==='object')visit(v[k],next,depth+1)}}
    visit(c,'',0);
   }
  }catch(error){failures.push(error instanceof IntegrationError?error.code:'consent_inspection_failed')}
 }
 return {verifiedAt:new Date().toISOString(),state:failures.length?'partial_access':'read_only_reviewed',facilitiesReviewed:facilities,mappedFacilities:links.length,customerRowsReviewed:examined,limitedFacilityCollections:limited,customerFields:[...root].sort(),communicationPreferenceFields:[...preferences].sort(),smsFields:[...sms].sort(),possibleEvidenceFieldPaths:[...proofPaths].sort(),suppressionSummary:{suppressed,unsuppressed,unknown},failures,affirmativeConsentInferred:false,consentsCreated:0,smsSubmitted:0};
}
