// Combination text is deliberately never trimmed, normalized or reformatted.
export function combinationProblem(value,confirmation,verified){
 if(typeof value!=='string'||typeof confirmation!=='string'||!value.length||!confirmation.length)return 'Enter and confirm the new combination.';
 if(value.length>200||confirmation.length>200)return 'Use a combination of 200 characters or fewer.';
 if(value!==confirmation)return 'The combinations must match exactly.';
 if(verified!==true)return 'Confirm that you checked the combination on the physical lock.';
 return '';
}
export function employeeError(error){
 if(error?.code==='40001')return 'This lock changed. Close it, reopen it, and try again.';
 if(error?.code==='55P03')return 'An access message is being processed for this lock. Please try again after its status is confirmed.';
 if(error?.code==='42501')return 'You do not have access to this action. Sign in again or contact an administrator.';
 if(error?.code==='invalid_credentials')return 'Check your email and password, then try again.';
 if(error?.code==='user_already_exists')return 'This account already exists. Sign in or reset your password.';
 if(error?.code==='over_email_send_rate_limit'||error?.status===429)return 'Please wait a moment, then try again.';
 return 'Unable to complete this action. Please try again.';
}
