import {connection} from 'next/server';
import TenantCombinationRequest from '@/components/tenant-combination-request';
import {tenantDirectory} from '@/lib/automation/tenant-directory.mjs';
export const metadata={title:'Request your lock combination | My Storage Locks',robots:{index:false,follow:false}};
export default async function Page(){
 await connection();
 let props={facilities:[],testMode:true,challenge:null} as any;
 try{props=await tenantDirectory()}catch{ /* Public fallback stays non-disclosing if the server connection is unavailable. */ }
 return <TenantCombinationRequest {...props}/>;
}
