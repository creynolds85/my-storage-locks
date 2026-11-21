import {createCipheriv,createDecipheriv,createHmac,generateKeyPairSync,privateDecrypt,publicEncrypt,randomBytes,constants} from 'node:crypto';

const normalOptions={oaepHash:'sha256',padding:constants.RSA_PKCS1_OAEP_PADDING};
const envelopeKey=secret=>createHmac('sha256',secret).update('msl-cubby-official-export-v1').digest();
function encrypt(key,raw){
 const nonce=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,nonce);
 const encrypted=Buffer.concat([cipher.update(raw),cipher.final()]);
 return Buffer.concat([nonce,cipher.getAuthTag(),encrypted]).toString('base64url');
}
function decrypt(key,base64){
 const raw=Buffer.from(base64,'base64url'),cipher=createDecipheriv('aes-256-gcm',key,raw.subarray(0,12));
 cipher.setAuthTag(raw.subarray(12,28));
 return Buffer.concat([cipher.update(raw.subarray(28)),cipher.final()]);
}
export function prepareCubbyExportEnvelope(secret,now=Date.now()){
 const {publicKey,privateKey}=generateKeyPairSync('rsa',{modulusLength:2048,
  publicKeyEncoding:{type:'spki',format:'pem'},privateKeyEncoding:{type:'pkcs8',format:'pem'}});
 const expires=now+10*60000;
 return {publicKey,expires,session:encrypt(envelopeKey(secret),Buffer.from(JSON.stringify({privateKey,expires})))};
}
export function sealCubbyExport(prepared,payload){
 const key=randomBytes(32);
 return {session:prepared.session,key:publicEncrypt({key:prepared.publicKey,...normalOptions},key).toString('base64url'),
  encrypted:encrypt(key,Buffer.from(JSON.stringify(payload)))};
}
export function openCubbyExport(secret,envelope,now=Date.now()){
 if(typeof envelope.session!=='string'||envelope.session.length>4000||
    typeof envelope.key!=='string'||envelope.key.length!==342||
    typeof envelope.encrypted!=='string'||envelope.encrypted.length>300000)throw Error('invalid_export_envelope');
 const {privateKey,expires}=JSON.parse(decrypt(envelopeKey(secret),envelope.session).toString());
 if(expires<now||expires>now+10*60000)throw Error('expired_export_envelope');
 const key=privateDecrypt({key:privateKey,...normalOptions},Buffer.from(envelope.key,'base64url'));
 if(key.length!==32)throw Error('invalid_export_envelope');
 return JSON.parse(decrypt(key,envelope.encrypted).toString());
}
