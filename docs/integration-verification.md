# Current production verification — November 6, 2026

The existing Operator Bearer token is present and authenticated. Scoped Facilities
Search returned all 23 mapped facilities and no unexpected facilities. Units,
Leases, Customers (including contact phone and SMS suppression), Payments,
Ledgers, Auctions and Delinquency Exemptions Search succeeded. Single-lease
compliance expansion is accessible. The representative verification completed in
1.052 seconds; calls took 80–413 ms. A broad lease/compliance expansion timed out
at 10 seconds; compliance is verified by individual lease instead.

The existing poller ran in shadow mode across all 23 facilities: 6,148 units,
69 API requests, 3.171 seconds, no database writes and no SMS. Source updates
were absent in that observation window, so real transition latency is unmeasured.
Provider rate limits remain unpublished; observed load completed without 429.

Production operational reads were then enabled with live SMS still disabled.
The active-record baseline completed at 2026-11-06 16:54:39 America/New_York:
4,387 lease snapshots, 6,148 unit mappings, and 23 facility cursors. Initial
snapshot writes are bounded to eight concurrent requests; historical leases are
excluded from initial seeding. Follow-up scheduled polls succeeded in 5.223 and
6.281 seconds. Operational polling runs before warehouse diagnostics. No physical
locks, combinations or assignments were modified.

A dummy public request with nonexistent rental details returned the fixed neutral
202 response and was blocked as rental_unverified, without a notification.
Real carrier delivery and controlled Cubby payment/rental transition acceptance
remain pending. A quiet source record's old updatedAt is not a replication delay.
General SMS stays disabled in both deployment and database approval gates.

Cubby Support confirmed no outbound webhooks. Operational monitoring uses direct
API polling; the earlier webhook discussion below is historical and superseded.
The configured key was neither replaced nor exposed.

---

## Historical pre-migration investigation

# Integration verification results — November 5, 2026

Observed production worker state at **4:57 PM America/New_York**. No live combination messages were enabled, no Twilio account settings were changed, and no physical inventory was written.

| Check | Observed result |
|---|---|
| Production implementation | Existing deployment READY on mystoragelocks.com; no rebuild of the infrastructure |
| Background schedule | 15/15 successful scheduled runs and authenticated endpoint responses in the measured 15-minute window; mean interval 59.998 seconds, maximum 60.081 seconds |
| Successful operational data synchronization | None; last successful sync remains NULL and baseline incomplete |
| Real Cubby event-to-processing latency | Not measured: no registered, authenticated operational event was received |
| Production facilities / locks / active assignments | 0 / 0 / 0 |
| Source reporting inventory | 1,146 locks; 13 facilities with locks; 23 source facilities total |
| Production mappings and active consent records | 0 facility mappings; 0 unit mappings; 0 consent records |
| Live SMS | Disabled in both deployment configuration and database; no live approval or activation timestamp |
| Provider SMS acceptance/delivery tests | Not performed; 0 submitted and 0 delivered notifications |

## Cubby access

The operational console successfully authenticated and displayed My Storage Ops and its normal facilities/settings. The connected reporting service also successfully queried the organization's source data. Neither connection supplies a deployed Operator API key.

Production and the local runtime have no `CUBBY_API_KEY`. A narrow unauthenticated connectivity probe to the actual facilities endpoint returned HTTP/envelope **401**, confirming authentication is required; that probe is not a successful API data read or an authenticated performance measurement. Actual operational response shape, permissions, pagination/completeness, rate limits and freshness remain unverified.

The credential correspondence found contains a BigQuery warehouse service account and an older confirmation that Lockerfox access was enabled. No Operator API key for My Storage Locks was located. No warehouse private key or other application's credentials were copied.

The current official API reference says keys are provisioned through Cubby support. Request a dedicated **read-only Search role**, authorized facilities, customer PII/communication preferences, lease compliance expansion, operational lease/unit/ledger/payment/auction reads, and `delinquency-exemptions/search`. No write, credit or waive permission is needed by My Storage Locks.

## Event contract finding

Cubby's published webhook documentation requires HTTP **200** to acknowledge delivery. The existing route used 202. This verification corrects the acknowledgment to 200 only after durable inbox acceptance; authentication and processing guards stay in place.

Subscriptions are configured per event type by Cubby. The documentation does not establish this organization's actual authentication headers/signature, retry limits or rate allocation. Those must be verified before enabling the webhook authentication flag.

The documented Overlock Remove Needed event is tied to a physical Cubby overlock still being on an active unit. It does not fire for automatically released smart locks. Confirm an operational clearance trigger that continues after the paid Combo Locks feature is removed. Do not claim an independently maintained local assignment will cause Cubby to emit this event. The lease polling fallback exists but has not performed an authenticated Cubby sync.

## Waivers and zero-charge rentals

Current code requires a latest SUCCEEDED payment plus a nonpositive ledger balance. It therefore fails closed for legitimate no-payment cases; these cases are not production-ready merely by approving the existing template.

The current official reference provides an active delinquency-exemption read containing lease/customer/facility identity, `pauseOverlock`, facility-local expiry and creator/time evidence. Its documentation states that this option can lift an existing overlock/gate restriction; other exemption options do not undo prior actions. It also explicitly supports creation of a lease without collecting payment. These are evidence candidates, not validated automatic release conditions.

Actual API examples are needed to distinguish a valid approved waiver, a credit-cleared account, and an authorized zero-charge/promotional move-in from unpaid or incomplete access. Any supported rule change must retain current lease/unit/tenant checks, all required move-in documents, cleared applicable restrictions, auction exclusion, verified consent and physical assignment, followed by controlled E2E testing and approval. Do not invoke Cubby's write/waive/create endpoints as a test.

## Migration reconciliation

A read-only validation over all 1,146 source rows found **0 invalid/missing IDs, serials or combinations; 0 duplicate source IDs or facility serials; 0 broken/cross-facility unit references; 0 unknown source statuses**. Fifteen units have multiple locks and must remain multiple records.

At this observation, 624 records are ACTIVE without an explicit physical-purpose classification and 7 are tenant-held. The current destination model cannot faithfully import these as Available or infer overlock/vacant/auction purpose. A fixed secure export, explicit source mappings and reviewed preservation of these states are still needed before applying production records. Source status counts move while Cubby remains in use. No import was applied and no existing combinations were overwritten.

## Twilio and acceptance blockers

No dedicated My Storage Locks Twilio account/API key, authentication token or Messaging Service SID is configured. No installable Twilio connector was found. Secure console sign-in accepted the email and password submissions but returned to login; a fresh console check did not show a signed-in account. This is not proof of an incorrect password or an account outage. Sender registration, dedicated service, signed callbacks, STOP/HELP and provider body-retention settings remain unverified. MSP was not accessed or modified.

Still required: authenticated Twilio console/API access; the dedicated Account SID, API Key SID/secret, callback validation Auth Token and Messaging Service SID; an approved registered sender; one explicitly designated controlled test number and consent evidence. Real event/provider delivery, duplicate handling under actual callbacks and failures, and unattended operation cannot receive a passed E2E result until these are available. Live tenant messaging stays disabled pending those results and explicit approval of the final release conditions/templates.

Sources reviewed directly: https://cubbystorage.github.io/docs/api/ and https://cubbystorage.github.io/docs/make-webhooks/ . These public documentation reads do not substitute for account-specific API permission or event tests.
