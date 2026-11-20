import {createClient} from 'npm:@supabase/supabase-js@2.119.0';
import {createInvitationHandler} from './handler.mjs';
const url=Deno.env.get('SUPABASE_URL')!;
const options={auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}};
Deno.serve(createInvitationHandler({
 callerFor:(authorization:string)=>createClient(url,Deno.env.get('SUPABASE_ANON_KEY')!,{...options,global:{headers:{Authorization:authorization}}}),
 mailerFor:()=>createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,options),
}));
