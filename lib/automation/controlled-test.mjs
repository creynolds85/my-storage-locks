import {CONTROLLED_FIXTURE_ID} from './controlled-test-identity.mjs';
export async function controlledTest(rt,{dispatch=false}={}){
 const info=await rt.store.call('controlled_sms_inspect');
 const generalDisabled=rt.env.LOCKS_LIVE_SMS_ENABLED==='false';
 if(!dispatch)return {...info,generalDisabled,testSendingEnabled:rt.env.LOCKS_CONTROLLED_SMS_TEST_ENABLED==='true',smsSubmitted:0};
 if(!generalDisabled||rt.env.LOCKS_CONTROLLED_SMS_TEST_ENABLED!=='true'||!info?.approved||info.suppressed!==false)return {state:'blocked',smsSubmitted:0};
 if(!(await rt.sender.verifyControlledSender()))return {state:'sender_not_ready',smsSubmitted:0};
 const claim=await rt.store.call('controlled_sms_claim');
 if(!claim||claim.fixtureId!==CONTROLLED_FIXTURE_ID)return {state:'blocked',smsSubmitted:0};
 let result;
 try{result=await rt.sender.sendControlledTest(claim)}catch{result={state:'unknown',errorCode:'provider_outcome_unknown'}}
 await rt.store.call('controlled_sms_result',{attemptId:claim.attemptId,providerSid:result.sid||null,state:result.state,errorCode:result.errorCode||null});
 return {state:result.state,smsSubmitted:result.sid?1:0};
}
