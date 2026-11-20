# Employee invitations and authentication emails

When email delivery is enabled, creating an active employee through Team access saves the approval, then requests an invitation. Permission edits and inactive-account saves send nothing. An existing authorized account has a separate Resend setup email action. The administrator UI distinguishes setup pending from a confirmed account with a password. Saving access and sending an email have separate outcomes; email failure never claims that an invitation was sent or rolls back the employee's access record.

## Trusted sending path

The `invite-employee` Supabase Edge Function uses its runtime-provided service-role credential only after verifying the caller with Auth and claiming a recipient through `account_invitation_claim`. That database operation requires the existing active administrator session, an active exact-match approval, and an enabled backend email-delivery switch. Role/facility permissions come exclusively from the approved access record. No privileged key is added to Vercel or shipped to a browser.

The Edge Function uses manual authentication (`verify_jwt=false` at the platform boundary) because the function performs its own `getUser` verification and the database verifies the live session and administrator role. Anonymous requests, non-administrators, expired sessions, inactive/unapproved recipients and foreign browser origins cannot send. The SMTP destination is fixed to `https://mystoragelocks.com/login`; the caller cannot supply a redirect or change access through the email endpoint.

Recipients without an Auth account receive a native invitation. Pending self-signups receive confirmation again; confirmed accounts receive a password-recovery/setup email. Invites and server-initiated recovery links are consumed explicitly with `setSession` in the browser because the SSR client requires PKCE, which native invitations do not support. Callback tokens are removed from the URL before asynchronous validation and are never logged or returned by the sending endpoint. Only a verified session reaches password setup. Standard browser signup/recovery keeps its existing PKCE flow.

## Attempts and errors

The private attempt record provides a per-recipient 60-second cooldown and a five-minute hold after an uncertain result. A provider timeout or failed outcome recording never triggers an automatic retry. The existing audit infrastructure records only the recipient, email kind and safe outcome code. Messages, action links, tokens, passwords and raw provider errors are excluded. Normal employee APIs have no direct access to the settings or attempt tables.

The login page has a Resend confirmation email action and specific explanations for unconfirmed addresses, email sending limits and obsolete links. Accepting an invitation opens the password form without requiring an email to be entered again.

## Production email setup

Configure custom SMTP in the My Storage Locks Supabase project. Use a verified sender, a sending credential scoped to that sender, and a bounded email rate. The authentication redirect allowlist must include `https://mystoragelocks.com/login?setup=1`. Disable provider click tracking for authentication links. Keep email confirmation enabled.

Test receipt and the password setup link using an authorized test recipient. Set `private.account_email_settings.enabled` to true only once delivery works. Team access indicates when email delivery is unavailable and allows administrators to save approvals in the meantime.

## Account removal

Select an account in Administration → Team access and choose Delete account. The confirmation identifies the email and requires a second action. A live administrator session is required. Administrators can't delete their own account. The operation uses the approval ID so a stale request can't delete an account created later with the same address.

Deletion removes the approval, any pending invitation record, facility memberships, and the Auth identity and sessions in one transaction. The inactive historical profile retains its display name and identifier for inspection and audit attribution. A subsequent approval can use the same email with a new identity. An in-flight invitation may delay deletion until its outcome is known.

## Verification

The account UI and invitation handler tests use controlled sessions and do not send live mail. The invitation and deletion SQL acceptance fixtures must run in a transaction that is rolled back.
