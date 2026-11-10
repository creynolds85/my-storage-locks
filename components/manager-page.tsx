import {connection} from 'next/server';
import LockManager from '@/components/lock-manager';
import {dailyLoginMessage} from '@/lib/login-messages.mjs';
export default async function ManagerPage(){
 await connection();
 return <LockManager loginMessage={dailyLoginMessage()}/>;
}
