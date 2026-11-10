export const MANAGER_LOGIN_PATH='/login';
export const MANAGER_DASHBOARD_PATH='/dashboard';
export function legacyManagerDestination(href){
 const url=new URL(href),hash=new URLSearchParams(url.hash.slice(1));
 if(url.pathname!=='/')return null;
 if(url.searchParams.has('code')||hash.has('access_token')||hash.has('error_description')||hash.get('type')==='recovery')return MANAGER_LOGIN_PATH+url.search+url.hash;
 if(['dashboard','inventory','admin'].includes(url.searchParams.get('view')))return MANAGER_DASHBOARD_PATH+url.search+url.hash;
 return null;
}
