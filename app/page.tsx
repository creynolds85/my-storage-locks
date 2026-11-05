import {connection} from 'next/server';
import LockManager from '@/components/lock-manager';
import {dailyLoginMessage} from '@/lib/login-messages.mjs';
export default async function Page(){
  // Resolve against the server clock on every page request, outside prerender/cache.
  await connection();
  return <LockManager loginMessage={dailyLoginMessage()}/>;
}
