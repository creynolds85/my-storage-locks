import {createServerClient} from '@supabase/ssr';
import {cookies} from 'next/headers';
import {redirect} from 'next/navigation';
import {managerSessionAllowed} from './manager-session.mjs';
export async function requireManagerSession(){
 const jar=await cookies();
 const client=createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,{cookies:{getAll:()=>jar.getAll(),setAll(){/* Browser client handles token rotation; this render never counts as activity. */}}});
 const {data,error}=await client.auth.getUser();
 if(error||!data.user||!await managerSessionAllowed(client))redirect('/login?expired=1');
}
