# Employee invitations and authentication emails

Creating an active employee through Team access saves the existing approval and then requests an invitation. Permission edits and inactive-account saves send nothing. An existing authorized account has a separate Resend setup email action. The administrator UI distinguishes setup pending from a confirmed account with a password. Saving access and sending an email have separate outcomes; email failure never claims that an invitation was sent or rolls back the employee's access record.

## Trusted sending path

The `invite-employee` Supabase Edge Function uses its runtime-provided service-role credential only after verifying the caller with Auth and claiming a recipient through `account_invitation_claim`. That database operation requires the existing active administrator session, an active exact-match approval, and an enabled backend email-delivery switch. Role/facility permissions come exclusively from the approved access record. No privileged key is added to Vercel or shipped to a browser.

The Edge Function uses manual authentication (`verify_jwt=false` at the platform boundary) because the function performs its own `getUser` verification and the database verifies the live session and administrator role. Anonymous requests, non-administrators, expired sessions, inactive/unapproved recipients and foreign browser origins cannot send. The SMTP destination is fixed to `https://mystoragelocks.com/login`; the caller cannot supply a redirect or change access through the email endpoint.

Recipients without an Auth account receive a native invitation. Pending self-signups receive confirmation again; confirmed accounts receive a password-recovery/setup email. Invites and server-initiated recovery links are consumed explicitly with `setSession` in the browser because the SSR client requires PKCE, which native invitations do not support. Callback tokens are removed from the URL before asynchronous validation and are never logged or returned by the sending endpoint. Only a verified session reaches password setup. Standard browser signup/recovery keeps its existing PKCE flow.

## Attempts and errors

The private attempt record provides a per-recipient 60-second cooldown and a five-minute hold after an uncertain result. A provider timeout or failed outcome recording never triggers an automatic retry. The existing audit infrastructure records only the recipient, email kind and safe outcome code. Messages, action links, tokens, passwords and raw provider errors are excluded. Normal employee APIs have no direct access to the settings or attempt tables.

The login page has a Resend confirmation email action and specific explanations for unconfirmed addresses, email sending limits and obsolete links. Accepting an invitation opens the password form without requiring an email to be entered again.

## Current deployment checkpoint

- Migration `20261119185703_employee_invitations` is applied.
- The guarded Edge Function is deployed; live anonymous and foreign-origin checks return 401 and 403.
- `private.account_email_settings.enabled` remains **false** until production SMTP configuration and an actual email-delivery check succeed.
- Frontend/source changes are prepared on a separate branch; the current production frontend is unchanged at this checkpoint.
- Supabase dashboard sign-in is paused at a human-verification challenge. Its SMTP configuration has not been inspected or changed in this session. Existing Auth logs confirm sending-limit errors.
- Do not mark the email problem resolved or send Courtney another setup email until the production sender has been configured and delivery verified.

## Completion procedure

Complete the existing Supabase sign-in verification, then inspect current Authentication email/SMTP settings and redirect allowlist. Configure a verified production sender through the selected email provider, preserve email confirmation, disable email-link click tracking where applicable, and set a bounded production email-send rate. Verify delivery of one controlled authentication email to the owner. Enable `private.account_email_settings.enabled` only after the sender is working, merge the prepared frontend change, verify production, and send Courtney's real invitation to her current active approved address. Keep her former Gmail approval inactive. The user must choose her own password.

## Validation

Ten isolated handler/callback checks and five controlled DOM checks cover authorization gates, duplicate prevention, ambiguous delivery, failure feedback, invite password setup, save-before-send order, inactive accounts, confirmation resends and expired-link cleanup. Existing login-message and lock-edit checks pass. Rollback-only database acceptance verifies actual administrator/session enforcement, recipient eligibility, cooldown, account provisioning, private-table denial and outcome auditing; all fixtures are rolled back. TypeScript and production compilation pass. No test emails have been sent and no employee password has been set.
