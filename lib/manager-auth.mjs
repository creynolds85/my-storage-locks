// The SSR client requires PKCE. Server-issued invites instead carry tokens;
// consume those explicitly with setSession, retaining the shared cookie store.
export function hasManagerTokens(url) {
 if (!url) return false;
 const hash=new URLSearchParams(new URL(url).hash.slice(1));
 return hash.has('access_token')&&hash.has('refresh_token');
}
export async function consumeManagerAuthCallback(client,url,replaceUrl) {
 const parsed=new URL(url),hash=new URLSearchParams(parsed.hash.slice(1));
 if(hash.has('error_code')){
  const code=hash.get('error_code')==='otp_expired'?'otp_expired':'email_link_invalid';
  parsed.hash='';replaceUrl(parsed.pathname+parsed.search);
  throw Object.assign(Error('Email link could not be verified'),{code});
 }
 if(!hasManagerTokens(url))return {handled:false,setup:false};
 const type=hash.get('type'),access_token=hash.get('access_token'),refresh_token=hash.get('refresh_token');
 parsed.hash='';parsed.searchParams.delete('setup');replaceUrl(parsed.pathname+parsed.search);
 const {error}=await client.auth.setSession({access_token,refresh_token});
 if(error)throw error;
 return {handled:true,setup:type==='invite'||type==='recovery'};
}
export function accountEmailError(error) {
 const code=error?.code;
 if(code==='email_not_confirmed')return 'Confirm your email before signing in. Check Junk or Spam, or use Resend confirmation email below.';
 if(code==='over_email_send_rate_limit')return 'The email service has reached its sending limit. Contact an administrator; repeatedly retrying will not resolve it.';
 if(code==='over_email_send_rate_limit_user')return 'Please wait a minute before requesting another email.';
 if(code==='otp_expired'||code==='email_link_invalid')return 'This email link has expired or has already been used. Request a new email and use the newest link.';
 if(code==='email_address_not_authorized')return 'The email service is not configured to deliver to this address. Contact an administrator.';
 return null;
}
