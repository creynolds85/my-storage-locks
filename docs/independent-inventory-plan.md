# Independent inventory and Cubby operational integration

Decision date: November 5, 2026. This supersedes the previous ongoing Cubby lock-authority recommendation. Status: architecture revised and documented access investigated. Continued account entitlement and runtime permissions remain unconfirmed. Migration, runtime integrations and live SMS have not been implemented or enabled.

## Concise implementation plan

1. **Confirm access:** validate the existing warehouse/export route for one-time migration; obtain operational API/PII/compliance access and authenticated events that remain available without paid lock management.
2. **Reconcile before import:** preserve the full snapshot, map immutable facility/unit/lock IDs, retain tenant-held/unclassified states, and show every existing-record conflict without overwriting it.
3. **Cut over once:** apply only the reviewed insert-only migration, verify/replay/backup it, then retire Cubby lock reads. Local physical records and actions are authoritative thereafter.
4. **Build operational notifications in dry run:** use fresh completed-rental or financial-clearance facts to evaluate the current local assignment and authorized, consenting tenant. Deduplicate events; create recovery/exception tasks; never mark Available automatically.
5. **Test, then obtain SMS release approval:** configure the transactional Twilio sender, signed callbacks, consent/STOP, safe retries, redaction and alerts. Prove the guarded flows end to end, then obtain explicit approval of conditions and templates before enabling tenant combination SMS.

**External gates:** Cubby confirmation of post-lock-feature entitlement, authenticated event/clearance semantics and runtime read permissions; a Twilio transactional sender/campaign configuration; documented access-message consent. The existing My Storage Ops warehouse account was confirmed by Cubby, but current credentials were not retrieved or copied. There is no permanent Cubby lock-module requirement in this design.

## 1. Ownership boundary

| Information or action | Authority after cutover |
|---|---|
| Physical locks, serials, combinations, condition, physical color, location, assignments, releases and recovery | My Storage Locks |
| Facilities/units, rental availability, leases, completed move-ins, delinquency/payment clearance and tenant identity | Cubby operational data, subject to confirmed entitlement |
| SMS consent/suppression decisions, deduplication, notification audit and staff recovery tasks | My Storage Locks; ingest Cubby preferences and Twilio opt-outs as additional restrictions |
| Carrier submission and delivery result | Twilio; delivery is not proof that the tenant read the message or recovered the lock |
| Original Cubby lock IDs/statuses/timestamps | Immutable migration provenance; never ongoing authority |

Keep the current application. No recurring lock-status sync, physical-lock write-back or normal operational dependency on Cubby's paid lock module is permitted. A Cubby or Twilio outage must not prevent authorized local assignment, release, combination lookup or inventory edits. It pauses automatic code disclosure and raises staff exceptions instead.

Core physical state and notification state remain separate. A release-eligible account, submitted SMS or delivered SMS cannot mark a lock Available. Staff must confirm physical recovery through the existing audited local workflow.

## 2. Access findings and genuine requirements

The current application has no Cubby connector. Its existing Supabase-backed lock operations already execute locally. The following capabilities are documented, but documentation does not establish this organization's commercial entitlement after removing the lock feature.

| Need | Documented read surface | What still needs confirmation |
|---|---|---|
| Facilities and unit identity/availability | facilities/search; units/search | Dedicated server credential, permitted facilities, enabled/rentability semantics, continued entitlement |
| Active leases, tenant/unit linkage and move-in dates | leases/search, with customer/unit/compliance expansions | Reliable completed-move-in signal; live state and freshness; access after feature removal |
| Documents and applicable move-in requirements | leases/search compliance expansion; leases/get-compliances | Permission for these reads; required-document set and which statuses actually permit access |
| Delinquency and payment clearance | leases/search overlockNeeded and ledger expansion; payments/search by leaseId | Explicit clearance policy, holds/auction data, payment settlement and reversal semantics independent of Cubby physical-lock state |
| Authorized tenant phone/preferences | customers/search: customerId, contact.phone and communicationPreferences.sms | Customer PII entitlement; consent evidence; primary leaseholder linkage and suppression flags |
| Events | Move In, Lease Documents Completed, auction events; Overlock Remove Needed is documented | Which events survive lock-feature removal, activation method, authenticity, stable IDs, ordering, retries and latency |
| One-time lock snapshot | Complete supported export, existing warehouse access or temporary locks/search access | All locks/combinations/source IDs and status distinctions; completeness beyond 1,000 rows; no permanent Locks role |

Cubby's October 7 support reply confirmed an existing My Storage Ops BigQuery service account, with credentials supplied to Kevin. This is evidence of an existing access route, not proof of current scope, realtime freshness or continued licensing. Do not copy credentials from another application's deployment, publish them in the repository, or ask for them in chat. Verify/provision scoped server access through the approved secret configuration route.

The connected reporting service currently exposes the required operational fields. An aggregate check found 3,703 contacts linked to active leases: 32 are DO_NOT_DISTURB and eight lack a primary phone. Contact preferences: **As of Nov 5, 7:09 PM UTC**; lease linkage: **As of Nov 5, 7:28 PM UTC**. No phone values were exported. Reporting availability is not an unattended website credential or a guarantee of fresh clearance data.

No matching account-specific confirmation that operational API/webhooks remain included without the paid lock feature was found in the inspected support correspondence. Obtain that confirmation before relying on those interfaces. Do not assume a public Search role includes every compliance/PII operation. Do not buy or retain a recurring lock-management subscription as an architectural prerequisite.

## 3. One-time migration and cutover

1. Obtain a complete snapshot while access remains available: stable organization/lock/facility/unit IDs, exact string serials/combinations/unit labels, raw status, condition/maintenance/location metadata and authentic timestamps. A supported one-time export or verified warehouse query is sufficient; a permanent lock API connection is unnecessary.
2. Preserve an encrypted original snapshot with batch identity and acquisition time. Keep combinations in private encrypted storage, separate from ordinary audit JSON and logs. Never place real codes in this document, fixtures, public files or Git.
3. Map Cubby facility ID to local facility UUID and Cubby unit ID + facility to a local unit reference. Keep the displayed unit label separately. Use source lock ID for migration identity, never unit name or unit ID alone. Fifteen units in the investigated snapshot have two locks.
4. Dry-run every record against the current local database. Report new/existing facilities, new/existing locks, serial collisions, combination/assignment conflicts, unmapped units, raw-status totals and unresolved classifications. Recheck current local versions before applying a batch. The earlier 1,146-lock/23-facility inventory audit is a baseline, not this completed dry run.
5. Use a unique organization + source lock ID mapping plus the existing facility/case-insensitive-serial constraint. Insert only absent records. Exact replays insert nothing; conflicting records are held for review. Never overwrite a local combination, assignment, history or facility to make totals agree. Use transactional batches within the existing importer limits or a dedicated reviewed importer.
6. Preserve all source distinctions. AVAILABLE/MISSING/DAMAGED map directly. Preserve the seven tenant-held locks as nonavailable, and preserve ambiguous operator-held assignments as assigned with classification required. Do not invent a purpose, physical color, assignment date or staff member. A minimal local tenant-held/unclassified representation is needed before these records can be applied; no production schema change has been made. Physical color can remain explicitly Unknown/Other until known, independent of status. Keep six dashboard cards and surface classification exceptions through the inventory/filter/action flow.
7. Verify totals by source ID, facility and raw/mapped status; verify all 633 attached-lock unit references, encrypted combination round-trip without printing codes, and multi-lock units. Prove replay creates zero duplicates. Compare conflicts again after any new local activity.
8. Establish a cutover timestamp and signed-off reconciliation. Take a local backup/restore checkpoint. Disable further lock imports and retire temporary lock-read credentials. From that point, local versions and assignment history win. Preserve the original source snapshot as provenance; do not replay it over later changes.

No historical import or initial operational baseline may generate tenant SMS. Only eligible events after the separately approved messaging activation time may do so.

## 4. Operational adapter and unit-to-lock resolution

Store Cubby operational snapshots separately from local physical-lock records. Each snapshot needs source organization/facility/unit/lease/customer IDs, source updated-at/version, observed-at time and freshness state. A facility/unit mapping change must not move a physical lock or transfer a local assignment automatically.

Use authenticated webhooks as wake-up signals, then fetch fresh authoritative operational facts before evaluation. A payload's topicId or source IP alone is not proof of origin. Confirm Cubby's supported signature/shared-secret mechanism; if authenticated delivery cannot be established, use authenticated polling rather than an unauthenticated disclosure trigger. Acknowledge only after durable acceptance. Record provider event identity where available and a canonical business-event key for deduplication.

Lease/customer searches document incremental updatedAfter/updatedBefore filters. Use a bounded overlap and deduplication instead of assuming timestamps form a lossless cursor; confirm enumeration limits and update behavior first. Baseline existing leases without sending old events. Preserve last-success time and alert on stale/missing data. Reporting/warehouse data can support migration and reconciliation, but must not authorize code disclosure unless its completeness and freshness meet an explicitly approved policy.

Resolve the current local assignment by local facility + immutable source unit reference + assignment purpose + open assignment identity. A unit label is not globally unique. There must be exactly one verified matching overlock or vacant-unit assignment. Multiple candidate locks, an auction assignment, tenant-held/unclassified state, stale mapping, retired/missing lock or a changed assignment causes no SMS and a staff exception. Never use physical lock color to select a lock.

## 5. Release conditions to approve

These are proposed guards, not active automation or final business approval. Missing or indeterminate evidence blocks disclosure.

### Overlock clearance

- Candidate: a documented Overlock Remove Needed event only if Cubby confirms it continues without the paid physical-lock module. Otherwise detect an independently entitled operational blocked-to-cleared transition using fresh lease/ledger/payment facts and an approved clearance rule. No generic payment-received webhook is established by the inspected documentation.
- Current active lease, facility, unit and primary customer must match the event and local assignment. The local purpose must be overlock; exclude auction/lien, unresolved holds and contradictory restrictions under the approved policy.
- Cubby must confirm that the required release amount/conditions are satisfied and that an overlock is no longer required. A payment amount, zero derived balance, or a paid-through date alone is insufficient. Confirm how manual waivers/exemptions affect the clearance rule.
- Payments Search includes attempts, pending funding, refunds, disputes and debit returns. One payment can cover several leases. Check current lease-level clearance/ledger attribution and the approved settlement policy; never release from the transaction's full amount or a pending/failed payment. Later reversals create a staff alert; they cannot retract a code already disclosed.
- Reconfirm assignment ID/version, local combination version, authorized primary tenant, current normalized phone, consent and suppression immediately before dispatch. Record a release episode to distinguish a later legitimate clearance from a retry of the same event.
- Create a local recovery task and notification audit. Leave the physical lock assigned until staff confirms recovery. Cubby's own webhook documents a still-attached lock after payment; a removal-needed flag is not physical recovery.

### Completed vacant-unit rental

- Candidate: Move In, documented as completed move-in/active lease, supplemented by fresh lease/unit/payment/compliance reads. A reservation, lead, checkout started, signature event or a single signed document is not sufficient.
- The rental must be completed, current, uncancelled and eligible for entry at the approved facility-local move-in time. Confirm required initial payment and all applicable requirements. Required documents must be APPROVED or explicitly NOT_REQUIRED; signing is not necessarily staff approval. Do not invent requirements for documents not applicable to the rental.
- The active primary tenant/customer must be authorized for the exact unit. Verify current phone and sender-specific access-message consent, and honor Cubby/Twilio/local suppression.
- The local lock must have a current vacant-unit assignment to that unit, present when the rental completed and still current at dispatch. Do not send codes for an auction, overlock, tenant-held, unrelated or ambiguous assignment. Support after-hours completion through the same approved guards, without adding a staff-presence requirement.
- Create a local recovery/follow-up task and notification audit. Sending the combination does not clear the physical assignment or make the lock Available.

## 6. Twilio design and security

Use Programmable Messaging and a dedicated My Storage Locks Messaging Service/sender configuration, not the claims portal's OTP Verify flow. Existing Twilio account use, sender/campaign ownership, permissions and registration are unverified; do not copy MSP credentials or change its Verify service. Confirm the sender/brand/campaign required for the chosen US number type (A2P 10DLC registration for a US long-code sender, or toll-free verification if that is the chosen route).

Retain evidence of transactional access-message consent: sender, purpose, disclosure/template version, tenant/customer identity, number, time and collection source. Cubby's default unsuppressed preference is not opt-in proof. Honor SYSTEM_UPDATES for transactional messages only when valid consent exists; never treat a marketing flag as the release condition. STOP in either system blocks future automated messages until valid re-opt-in. HELP and staff fallback must work. A phone belonging to an alternate contact, payer or lead is not automatically authorized for the unit's combination.

Use a durable private event inbox and outbox. Unique notification identity should include purpose + lease + local assignment + release/rental episode, not just a provider event ID or phone number. Duplicate webhooks, polling and multiple document events must converge on the same notification. A changed recipient does not silently create another send. Use transactional worker claims and serialize assignment/combination changes against pre-dispatch validation.

Persist the intent, opaque dispatch-attempt ID and recovery task before external dispatch. Decrypt/render the combination only inside the sender at the final step. Store template ID/version and local secret-version reference in the audit, never plaintext body/code or a reversible low-entropy code fingerprint. Do not log raw callback/webhook bodies, SDK request/error dumps or codes in URLs, analytics, emails or alert text.

Persist Twilio MessageSid and distinguish accepted/queued/sent/delivered/undelivered/failed. Validate X-Twilio-Signature using the maintained SDK, expected account and exact public callback URL/parameters. Handle callback duplicates and out-of-order statuses without regressing a final result. Record event and observation timestamps; carrier delivery is not a read receipt. Alert staff for rejection, failed/undelivered messages, stale pending/unknown status, missing consent, invalid recipient and mapping conflicts. Alerts contain internal references and redacted destinations, never combinations.

Do not promise provider-level exactly-once sending: an outbound timeout after Twilio accepted a request can leave an unknown outcome. Mark it unknown and reconcile via MessageSid or an authenticated callback correlated with the opaque attempt ID; do not blindly retry. Confirm provider idempotency support before relying on it. An intentional resend requires renewed eligibility checks and an audited staff action, not an automatic retry on missing delivery status.

Use short, explicitly approved intent expiry/queue validity, cancel stale pending intents when assignments/tenants/secrets change, and revalidate just before dispatch. Once a provider has accepted an SMS, retraction is not guaranteed. Recovery should address any disclosed or in-flight combination before reuse, including a local combination change when supported. Normal local inventory work remains independent of the provider.

Evaluate Twilio message-body redaction/contentRetention=discard and limited provider log access before live use. Redaction is not zero provider/carrier retention. Preserve functioning STOP suppression; do not blindly apply a phone-redaction configuration that disables Twilio's built-in STOP filtering. Confirm the selected account's redaction entitlement and compatible opt-out configuration. Retain audit metadata and delivery events without retaining the secret-bearing body.

## 7. Draft templates — not approved or sent

Overlock: "[Facility] / My Storage Locks: Your unit is cleared for overlock removal. Unit [Unit], lock [Serial], combination [Code]. Please return our lock to [Return instructions]. Reply STOP to opt out; HELP for help."

Rental: "[Facility] / My Storage Locks: Your rental for Unit [Unit] is ready. The facility lock [Serial] opens with [Code]. Please return our lock to [Return instructions]. Reply STOP to opt out; HELP for help."

The sender identity, return instructions, release wording, timing and consent language require approval. Do not send either template with real combinations during investigation or dry run.

## 8. Implementation and acceptance sequence

| Stage | Concrete result | Release boundary |
|---|---|---|
| A. Access contract | Confirm one-time export; operational API/PII/compliance/webhook access and continued entitlement without the lock feature | No data apply, no SMS |
| B. Migration preparation | Private snapshot, local facility/unit mapping, faithful imported-state representation, complete dry run and conflict reconciliation | Review before production apply |
| C. Cutover | Insert-only approved import, replay/restore checks, local audit/provenance, migration access retired | Independent physical inventory |
| D. Operational integration | Read-only operational snapshots and authenticated events/polling; local task and exception handling | Dry-run eligibility/outbox only |
| E. SMS acceptance | Approved guards/templates/consent; sender configuration; focused integration and controlled delivery testing | Explicit approval before tenant combination SMS |

Required tests include: feature removed/API denied while local CRUD/reveal/release still works; repeat import and concurrent local conflicts; complete string/secret preservation; two locks on one unit; same unit label at different facilities; stale/reordered/forged events; post-activation event boundary; pending/failed/refunded/multi-lease payments; auction/lien holds; partial signatures and future/cancelled rentals; wrong/changed tenant/phone; no consent/STOP; multiple/no matching locks; assignment/combination changed after enqueue; simultaneous retries; timeout with unknown provider outcome; signed duplicate/reordered delivery callbacks; failed-message alerts; recovery tasks; and no automatic Available transition.

Use Twilio simulation/test facilities where available, but do not call them delivery acceptance: Twilio test credentials do not deliver SMS or trigger status callbacks. Complete signed-callback tests and, only with explicit test-recipient approval, controlled delivery using a disposable test lock/code. A trial/test setup is not proof of production sender registration. Do not enable live tenant codes until focused end-to-end evidence and explicit approval of release conditions and templates are recorded.

## Sources and evidence

- [Cubby API reference](https://cubbystorage.github.io/docs/api/): operational searches, role/PII restrictions, customer preferences, lease compliance, payment attempts/attribution and incremental lease/customer reads.
- [Cubby webhook reference](https://cubbystorage.github.io/docs/make-webhooks/): Move In, document completion, auction, overlock and removal-needed event meanings. Account entitlement/authentication details remain unconfirmed.
- Cubby support, October 7, 2026, Server-to-Server API Access thread: existing My Storage Ops BigQuery service account supplied to Kevin. No credentials were retrieved.
- Connected Cubby reporting schema and aggregate checks; earlier [inventory assessment](cubby-integration-assessment.md) preserves the investigated inventory snapshot and facility roster.
- [Twilio Messaging Policy](https://www.twilio.com/en-us/legal/messaging-policy), [US A2P 10DLC](https://www.twilio.com/docs/messaging/compliance/a2p-10dlc/quickstart), [Messages resource](https://www.twilio.com/docs/messaging/api/message-resource), [webhook security](https://www.twilio.com/docs/usage/webhooks/webhooks-security), [message redaction](https://www.twilio.com/docs/messaging/guides/privacy-message-redaction), and [test-credential limitations](https://www.twilio.com/docs/iam/test-credentials).

No production data, runtime code, credentials, subscriptions, webhooks or SMS settings were changed for this architecture revision. No vendor or tenant messages were sent.
