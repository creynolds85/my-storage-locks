import {createBrowserClient} from "@supabase/ssr";
import {hasManagerTokens} from './manager-auth.mjs';
export function db(){return createBrowserClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,{auth:{detectSessionInUrl:!hasManagerTokens(typeof window==='undefined'?null:window.location.href)}})}
