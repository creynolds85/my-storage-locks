import {digest} from './policy.mjs';
import {CONTROLLED_FIXTURE_ID,CONTROLLED_PHONE,CONTROLLED_PHONE_HASH,CONTROLLED_BODY_HASH} from './controlled-test-identity.mjs';
export function controlledClaimAllowed(env,claim,now=Date.now()){
 const approved=Date.parse(claim?.sendApprovedAt),expires=Date.parse(claim?.approvalExpiresAt),checked=Date.parse(claim?.suppressionCheckedAt);
 return env.LOCKS_LIVE_SMS_ENABLED==='false'&&env.LOCKS_CONTROLLED_SMS_TEST_ENABLED==='true'
  &&claim?.fixtureId===CONTROLLED_FIXTURE_ID&&claim?.fixtureVersion===1&&claim?.scope==='single_controlled_test'
  &&claim?.phone===CONTROLLED_PHONE&&claim?.phoneHash===CONTROLLED_PHONE_HASH
  &&typeof claim?.body==='string'&&digest(claim.body)===CONTROLLED_BODY_HASH
  &&claim?.bodyHash===CONTROLLED_BODY_HASH&&claim?.reserved===true&&claim?.suppressed===false
  &&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(claim?.attemptId||'')
  &&Number.isFinite(approved)&&approved<=now&&Number.isFinite(expires)&&expires>now&&expires-approved<=900000
  &&Number.isFinite(checked)&&checked<=now+5000&&now-checked<=30000;
}
