import TenantRequestPage from '@/components/tenant-request-page';
import LegacyManagerRedirect from '@/components/legacy-manager-redirect';
export const metadata={title:'Request your lock combination | My Storage Locks',description:'Request verified facility lock access instructions or contact your storage facility.'};
export default async function Page(){
 return <><LegacyManagerRedirect/><TenantRequestPage/></>;
}
