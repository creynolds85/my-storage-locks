import {connection} from 'next/server';
import TenantCombinationRequest from '@/components/tenant-combination-request';
import {tenantDirectory} from '@/lib/automation/tenant-directory.mjs';
export default async function TenantRequestPage(){
 await connection();
 let props={facilities:[],testMode:true,challenge:null} as any;
 try{props=await tenantDirectory()}catch{ /* Same non-disclosing fallback as the existing request page. */ }
 return <TenantCombinationRequest {...props}/>;
}
