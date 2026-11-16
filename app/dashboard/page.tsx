import ManagerPage from '@/components/manager-page';
import {requireManagerSession} from '@/lib/manager-session-server';
export const metadata={title:'Lock Manager | My Storage Locks'};
export default async function DashboardPage(){await requireManagerSession();return <ManagerPage/>}
