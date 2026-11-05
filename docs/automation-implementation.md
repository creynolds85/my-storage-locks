# Cubby operations and unattended combination notification infrastructure

Implemented 2026-11-05. Live SMS remains disabled. My Storage Locks owns physical locks, secrets, assignments and physical recovery. Cubby supplies operational facts only. No Cubby write transport or Combo Locks runtime dependency exists.

## What is implemented

- Durable SQL inbox, per-event leases/retries, durable notification outbox, stable business-event deduplication, audit attempts, current-data verification and separate live gates in server configuration and database.
- Authenticated Cubby endpoints under `/api/integrations/cubby/{move-in,overlock-clearance,lease-changed,document-completed,auction-changed}`. An accepted event is saved before HTTP 202. Its eligible notification is processed immediately through Next `after`, without waiting for cron or a logged-in employee. Cron retries unfinished work.
- A database cron job runs every minute and calls `/api/automation/tick` using a dedicated server secret from Vault. It also detects missing heartbeats, stale operational data and uncertain dispatches. It operates independently of employee sessions. The minute is a target, not an API freshness guarantee.
- Incremental lease/customer queries with a two-minute overlap, stable unit identifiers, initial baseline with no historical notifications, and cursor advancement only after work is durably saved. Unit reads are currently full-facility because a supported incremental contract has not been verified.
- Fresh operational fetch immediately before dispatch; a final SQL claim rechecks assignment/version, source episode, recipient hash, consent, suppression, payment/access facts, approval/version, freshness and exactly one assignment. Combinations are decrypted only for a reserved, approved live dispatch.
- Dedicated Twilio API-key/Messaging Service configuration, signature-checked callbacks, timestamped status history, STOP suppression, provider body discard request, no code-bearing application logs, no automatic retries after uncertain submission.
- Dashboard action items for recovery, missing/conflicting assignments, SMS failures and synchronization failures. Eligibility, notification and physical recovery are separate states. Only authorized staff physical-recovery confirmation invokes the existing release function.
- Ordinary inventory operations continue through their existing local APIs. Notification or Cubby failures do not change physical inventory.

## Access verification still required

The connected Cubby reporting interface proves read access to reporting data; it is not a deployable operational API credential, webhook subscription or a one-minute service guarantee. The user's continued normal Cubby product access is accepted. No further Combo Locks entitlement is assumed or required at runtime.

1. Provision a **server-only Cubby operational API key** for this application and verify reads for facilities, units, leases with compliance expansion, customers including contact/communication preferences, ledgers, payments and auctions. Confirm tenant phone PII permission and primary-tenant authorization semantics.
2. Verify actual response examples against the adapter and confirm rate limits, complete collection/pagination behavior, timestamp precision, incremental filters and `facility.timeZone`. Initial safety cap rejects collections of 1,000 or more until completeness is established. Default budget is 120 API calls per worker runtime; each lease verification requires seven reads, so size/rate measurements are needed before enabling the one-minute data poll.
3. Register completed Move In and Overlock Remove Needed events where supported. Verify actual authentication, headers, IDs, timestamps, retry and delivery semantics. Generic payment webhook support is not established. Do not turn on `CUBBY_WEBHOOK_AUTH_CONFIRMED` based on assumed headers. If Cubby cannot authenticate callbacks directly, use a separately authenticated relay; polling remains available.
4. Provision a **separate My Storage Locks Twilio Messaging Service**, API key, approved sender/registration, signed inbound/status callback URLs and body-retention controls. Do not copy or modify MSP claims portal credentials/services. Verify STOP/HELP behavior and retention in the actual account.
5. Establish scoped SMS permission evidence covering these access messages. Cubby's unsuppressed/default messaging preference alone is not proof of consent. The consent RPC records source/version/time tied to the verified tenant phone; STOP revokes it. A new verified re-opt-in workflow is needed after STOP.

These are configuration/contract checks, not paid lock-module licensing blockers. With missing credentials or unverified limits, the scheduled worker records configuration-needed status; it does **not** claim successful operational synchronization.

## Draft release conditions — approval required before live use

Common: fresh API-verified active/current lease, correct stable facility/unit/customer, no applicable auction, no unresolved access restriction, exactly one current matching physical assignment that existed at the event, current authorized primary phone, verified scoped consent, no suppression, correct template version and an event after activation. No manager/session dependency.

Overlock: an observed `overlockNeeded: true -> false` transition for the same lease; current ledger `totalDue <= 0`; latest payment `SUCCEEDED`; no other holds. The unit's physical `overlocked` flag may remain true until recovery and is not treated as an instruction to release local inventory. A payment attempt alone cannot qualify.

Rental: completed Move In event, newly created active lease found by polling, or previously inactive lease becoming current; move-in date reached in facility time zone; all required documents approved/not required; current ledger clear; latest payment succeeded; correct vacant lock. Reservations, future move-ins and incomplete documents cannot qualify. Zero-charge/no-payment move-ins currently fail closed and require a separately approved rule.

`restrictionsClear` currently depends on the verified operational contract plus auction clearance and lease/payment conditions. **Do not certify the contract until actual Cubby access-hold semantics are proven**; any additional hold fields must be mapped and tested first. Public documentation does not establish a universal all-holds-cleared field.

One release episode produces at most one automatic notification even if its physical assignment later changes. Assignment changes, phone changes, conflicts and uncertain submissions produce action items rather than replaying a code. A provider-accepted attempt is never blindly resubmitted. Current-data verification failures keep work durable or raise a staff action. Pending messages expire after two minutes and require review rather than unsafe delayed disclosure.

## Draft templates — not activated

**Overlock clearance:** `{Facility} / My Storage Locks: Your unit is cleared for overlock removal. Unit {Unit}, lock {Serial}, combination {Combination}. Please return our lock to {ReturnInstructions}. Reply STOP to opt out; HELP for help.`

**New rental:** `{Facility} / My Storage Locks: Your rental is ready. Unit {Unit}, lock {Serial}, combination {Combination}. Please return our lock to {ReturnInstructions}. Reply STOP to opt out; HELP for help.`

Facility-specific return instructions are required. Do not mention auction or unrelated locks. Template version: `2026-11-05-draft-1`.

## Controlled activation procedure

1. Verify the actual API/webhook contracts, configure facility mappings/return instructions, confirm source-to-local unit links, establish the baseline and review sync latency/rate measurements. Watch the dashboard's successful synchronization timestamp, not only its worker heartbeat.
2. Load consent evidence only from verified actual permission records. Run test records through all 14 requested scenarios; use fixture combinations and controlled test recipients only. Twilio test credentials do not exercise actual delivery callbacks; use a dedicated controlled recipient for the focused delivery test.
3. Verify both immediate webhook-to-dispatch behavior and missed-event polling detection, signed delivered/failed callbacks, STOP, uncertain-provider reconciliation, assignment change before dispatch, and operation with no employee session. Dashboard alerts currently persist in-app; an external escalation channel/recipient has not been configured or sent messages.
4. Present measured E2E results and exact final conditions/templates for **explicit user approval**. Until then leave `LOCKS_LIVE_SMS_ENABLED=false`, database `mode=dry_run`, `acceptance_passed=false`, `live_approved_at=null`, `activation_at=null`.
5. After approval, coordinate the database and server latches with a new activation timestamp and exact policy version; historical dry-run rows never become live automatically. Monitor early controlled production events. Disable the server flag and database mode immediately to pause future dispatch; physical operations remain local.

## Verification

`npm test` covers policy, adapter, authentication, polling, retries, provider callback signatures, template requirements, migration reconciliation, inventory and routing. The production Next build validates API handlers and TypeScript. `tests/automation.acceptance.sql`, wrapped in BEGIN/ROLLBACK after all automation migrations, validates database latches, duplicate prevention, encrypted secret claim with fixture code only, callback ordering, current assignment changes, STOP, role isolation and explicit employee recovery. The controlled live-gate portion is rolled back and never calls Twilio. It is not the real-provider acceptance approval.
