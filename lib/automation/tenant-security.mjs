import {createHmac,randomUUID,timingSafeEqual} from 'node:crypto';
import {normalizePhone,digest} from './policy.mjs';
import {REQUEST_CONSENT_VERSION} from './sms-disclosure.mjs';
export {TENANT_RESPONSE} from './tenant-response.mjs';
export function requestHash(secret,purpose,value){if(!secret)throw Error('request_configuration_missing');return createHmac('sha256',secret).update('tenant-access-v1:'+purpose+':'+value).digest('hex')}
export function requestChallenge(secret,now=Date.now()){const nonce=randomUUID(),issuedAt=String(now);return {nonce,issuedAt,signature:requestHash(secret,'challenge',nonce+':'+issuedAt)}}
export function validChallenge(secret,c,now=Date.now()){
 if(!secret||!c||!/^\d{13}$/.test(c.issuedAt||'')||!/^[0-9a-f-]{36}$/i.test(c.nonce||'')||!/^[0-9a-f]{64}$/.test(c.signature||''))return false;
 const age=now-Number(c.issuedAt);if(age<1500||age>1800000)return false;
 const expected=requestHash(secret,'challenge',c.nonce+':'+c.issuedAt);return timingSafeEqual(Buffer.from(expected),Buffer.from(c.signature));
}
/** @param {any} body @param {{secret?:string,ip?:string,now?:number}} options */
export function tenantInput(body,{secret,ip,now=Date.now()}={}){
 if(!body||typeof body!=='object'||body.website||!validChallenge(secret,body.challenge,now)||!ip||ip.length>100)return null;
 const facility=String(body.facility||''),unit=String(body.unit||'').trim(),phone=normalizePhone(body.phone);
 if(!/^[a-f0-9]{24}$/.test(facility)||!unit||unit.length>60||/[\u0000-\u001f\u007f]/.test(unit)||!phone||!/^[0-9a-f-]{36}$/i.test(body.requestKey||''))return null;
 return {facility,unit,phoneDigest:digest(phone),phoneRateHash:requestHash(secret,'phone',phone),ipHash:requestHash(secret,'ip',ip),unitHash:requestHash(secret,'unit',facility+':'+unit.toLowerCase()),dedupeKey:requestHash(secret,'dedupe',body.requestKey),nonceHash:requestHash(secret,'nonce',body.challenge.nonce),smsConsent:body.smsConsent===true,consentVersion:REQUEST_CONSENT_VERSION};
}
