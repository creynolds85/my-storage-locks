# Cubby integration assessment — My Storage Locks
Date: November 5, 2026. Investigation only; no production inventory writes or Cubby write-back.

## Finding
Do not ask staff to recreate the existing inventory. The connected Cubby reporting service exposes 1,146 physical locks, with serials and combinations populated on every record. Thirteen facilities have locks; 23 facility records are available.

Reporting freshness: door_locks, facilities and lease_auctions — **As of Nov 5, 6:10 PM UTC**. Units — **As of Nov 5, 6:26 PM UTC**. Leases — **As of Nov 5, 6:30 PM UTC**. These are reporting snapshots, not a claim of instantaneous REST freshness.

## Existing application
The production source baseline examined was 194cb2a76db44c4243b2ab809724c1d508be4624. It contains Supabase authentication/data access, audited lock operations and CSV import/export, but no Cubby client, inbound webhook, polling job or external-ID mapping. Vercel environment metadata contains only the Supabase public URL and publishable key; no Cubby credential is configured. The ChatGPT reporting connection is functional, but is not an unattended runtime credential for the website.

Read-only inspection of the live My Storage Locks Supabase database found zero facilities and zero locks at the time of review. This is a point-in-time observation; the importer must recheck immediately before applying any batch.

## Verified source inventory
| Reporting status | Count | Meaning |
|---|---:|---|
| AVAILABLE | 479 | No attached unit |
| ACTIVE | 626 | Operator-held lock attached to a unit |
| IN_TENANT | 7 | Tenant-held lock attached to a unit |
| MISSING | 24 | Missing |
| DAMAGED | 10 | Damaged |
| Total | 1,146 | 633 attached; 513 not attached |

Data checks found:
- No blank serials, combinations or lock IDs.
- No duplicate lock IDs, case-insensitive facility/serial pairs, or serials reused across facilities.
- All source facility references resolve, and all 633 attached-lock unit references resolve.
- All serials fit the current application's alphanumeric/100-character validation.
- Fifteen units each have two locks (30 locks total). Never deduplicate by unit.
- Two tenant-held locks have a maintenance flag. Maintenance is not equivalent to DAMAGED.
- No company-stock records without a facility, and no populated custom locations, in this snapshot. The source schema can represent both.
- No physical-color column is exposed in the lock reporting schema or documented Lock Search response. Do not infer color from status.

## Available fields and documented API
Official references: [Cubby API](https://cubbystorage.github.io/docs/api/) and [Cubby webhooks](https://cubbystorage.github.io/docs/make-webhooks/).

| Needed value | Verified reporting field | Documented REST field/source |
|---|---|---|
| Stable lock identity | door_locks.door_lock_id | locks/search: lockId (id is deprecated) |
| Serial | serial_code | serial |
| Combination | combination | combo |
| Facility | facility_id | facilityId |
| Attached unit | unit_id | attachedTo; resolve unit name via units/search |
| Status | status | status plus disabledReason |
| Unit label | units.unit_name | units/search: name |
| Facility identity/name/address | facilities.facility_id, facility_name, address | facilities/search: facilityId, name, contact; enabled also documented |
| Record timestamps | door_locks.created_at, updated_at | Not documented on Lock Search |
| Maintenance/custom location | needs_maintenance, custom_location | Not documented on Lock Search |
| Physical lock color | Not exposed | Not documented |

Documented read endpoints are POST /v1/locks/search, /v1/facilities/search, /v1/units/search, with lease/auction searches for context. POST is the method for searches; these are read operations. New lock searches should send exactly one scope under where, e.g. organizationId. The older top-level scope and response id remain supported but deprecated.

The REST status vocabulary differs from reporting:
- AVAILABLE
- OPERATOR_USE
- TENANT_USE
- DISABLED with disabledReason DAMAGED or MISSING

Validate this translation and the correspondence of reporting door_lock_id to REST lockId against an authenticated response before implementing an adapter.

## Status mapping requires a decision
| Source state | Proposed treatment |
|---|---|
| AVAILABLE / AVAILABLE | Available, preserving combination and source identity |
| MISSING / DISABLED + MISSING | Existing missing status |
| DAMAGED / DISABLED + DAMAGED | Existing retired status, shown as Damaged / Retired |
| ACTIVE / OPERATOR_USE | Preserve source assignment and unit first; derive Overlocked/Vacant/Auction only under approved rules |
| IN_TENANT / TENANT_USE | Preserve tenant-held state and unit; never label Available or silently force it into operator assignment categories |

The 626 ACTIVE locks break down into disjoint unit-state groups:
- 532 on unleased, rentable units without an overlock flag.
- 24 on leased, overlocked units.
- 2 on unleased, unrentable units with an overlock flag.
- 24 on unleased, unrentable units without an overlock flag.
- 44 on leased units without an overlock flag.

Eight of the 24 leased/overlocked records also have an active lease marked in auction. That overlap needs an explicit display rule; a lease's auction process does not by itself identify the physical lock's assignment purpose. The 44 leased/non-overlocked records have no active-auction flag. All seven IN_TENANT records are on leased/non-overlocked units and have no active-auction flag.

These are contextual flags, not proof of the purpose of each physical lock. Preserve raw source status and source unit rather than inventing categories. The current six underlying application statuses cannot faithfully express tenant-held or unresolved operator-purpose assignments. Stage all source records first and resolve that representation before committing an initial import; do not import unresolved records as Available.

Cubby's Overlock Remove Needed webhook explicitly describes a paid tenant whose physical lock is still on the door: lease.overlockNeeded is false while unit.overlocked remains true. Payment or removal-needed alone must not return a physical lock to Available.

## Facility mapping
All 23 facilities can be read and mapped using immutable Cubby facility IDs; display names and addresses can be populated automatically. Use a persistent source-facility-ID to local UUID mapping, not name-only matching. Read REST enabled before setting a facility active. Existing local facilities must be matched and reviewed, never renamed or merged blindly. Facility import must not grant employees new memberships automatically.

| Cubby facility | Cubby facility ID | Locks |
|---|---|---:|
| 1651 Self Storage | `fac_JrfgDEqZqM8` | 0 |
| Anchor Self Storage of Cornelius | `fac_Hgnr1oHiwep` | 197 |
| Anchor Self Storage of Huntersville | `fac_GpCA6wM8WbS` | 82 |
| Anchor Self Storage of Lake Wylie | `fac_B9sWsUHFvak` | 78 |
| Atlantic Business Storage | `fac_SMB1fsU3vuD` | 0 |
| Atlantic Self Storage | `fac_HYNXKkqng6F` | 0 |
| Cedar Point Self Storage | `fac_RfhtUTryFwM` | 0 |
| EZ Store and Lock | `fac_XNJuMKPfhDP` | 0 |
| Grannys Mini Storage | `fac_GSoc2arucCr` | 0 |
| NoDa Self Storage | `fac_GkcRDcvtizJ` | 97 |
| Rethink Self Storage | `fac_BmvD2RZ2zG4` | 0 |
| Ridge Mini Storage | `fac_U4jghcjdz8b` | 15 |
| Roll Up Self Storage of Blowing Rock | `fac_Nj5rywKPjVk` | 0 |
| Roll Up Self Storage of Davidson | `fac_EEaTj8mBbZU` | 170 |
| Secure Mini Warehouses | `fac_Ci5kuPhJR7L` | 45 |
| Snuglock Self Storage | `fac_J7hqLSJ8ypU` | 0 |
| Storage Ninja | `fac_JXExXzb7ZNu` | 0 |
| Storehouse Self Storage of Banner Elk | `fac_VaEfDccF44H` | 122 |
| Storehouse Self Storage of Clover | `fac_EyjGDnTiTEQ` | 60 |
| Storehouse Self Storage of Grandfather | `fac_VaPfjDhp6NF` | 91 |
| Storehouse Self Storage of Hendersonville | `fac_NxLEBiS4QXR` | 110 |
| Storehouse Self Storage of Orchard Lane | `fac_HRHUUEzfUaF` | 36 |
| Summit Mini Storage | `fac_WLGqn9M2Be9` | 43 |

## Proposed initial import
This is the proposed implementation, not a completed import.
1. Confirm a dedicated server-side credential can read locks including combo, facilities, units and required lease/auction context. Reconcile an authenticated full response with these reporting counts.
2. Pull into private encrypted staging with an import batch ID, source IDs, raw status, source unit/facility IDs, source timestamps where available and retrieval time. Keep serials, combinations and unit labels as strings. Do not put combinations in logs, audit JSON, analytics or client bundles.
3. Produce a dry run: facility matches/new facilities, new locks, exact existing matches, duplicate/conflicting serials, changed combinations, assignment conflicts and unresolved statuses. Review roster and status rules before apply.
4. Store a unique source organization + source lock ID mapping to each local lock UUID. Use facility + case-insensitive serial only as a secondary conflict check. A transfer keeps the same source lock identity.
5. Apply bounded insert-only transactions, creating only absent source-owned records. Existing records, combinations, assignments and histories remain untouched. Skip exact repeats without creating activity; quarantine differences instead of overwriting them. Recheck for changes under the transaction before insertion.
6. Preserve initial source assignments as imported snapshots. Do not fabricate historical assignment dates or staff identity from the import timestamp or lock creation date. Retain genuine source timestamps separately from imported-at time.
7. Reconcile totals by facility/status and source lock ID. Re-run the same batch to prove it inserts zero additional records. Record batch provenance and audit results.
8. Keep company stock and unknown facilities unresolved if encountered rather than fabricating a facility.

The existing CSV importer is transactional and preserves the existing underlying statuses, but accepts a maximum of 1,000 rows per call, requires a facility and physical color, and has no Cubby source-ID/replay mapping or tenant-held representation. It is not a safe complete Cubby adapter. Do not feed all 1,146 records through it blindly or substitute default Available statuses.

## Ongoing synchronization recommendation
Use Cubby as the source of truth for imported serials, combinations, facility placement, attached units and source status. Lock Manager becomes the operational viewing/search layer, with locally owned notes and physical-color enrichment kept separate. Imported source-owned fields should not be independently editable in two systems while write-back is prohibited; preserve existing local-only workflows for separately owned records.

Start with a read-only server-side snapshot/diff poll after Cubby confirms rate and completeness behavior. A proposed five-minute interval is a starting point for evaluation, not an established service guarantee. Retain last-success/as-of time, retries with backoff and a daily full reconciliation. No automatic deletions when a response is partial, fails, or omits a previously seen lock.

Do not overwrite existing records under the current authorization. For any later approved sync, define source ownership and conflict handling explicitly: if a local record changed since the previous sync, or a combination differs, stop and present a reviewed conflict instead of using last-write-wins. Keep both source and local provenance.

Documented webhooks include move-in/out, auction scheduled/entered/exited, Tenant Overlocked and Overlock Remove Needed. They can accelerate a subsequent authoritative refetch. They do not document complete lock-register/return/transfer/disable/combination-change coverage, so they cannot replace reconciliation. Their activation is arranged with Cubby support. Confirm delivery authentication, replay identifiers and retries before using them. No outbound Cubby mutation endpoints are part of this approach.

## Confirmed limitations and unresolved access
- The connected reporting tool can read the fields today; an authenticated production REST fetch has not been performed. No Cubby website credential is configured.
- The API reference's Search role lists facilities/units/leases/auctions but does not list Locks. The Locks role lists search plus register/disable/attach/return/transfer. Request least-privilege lock search plus required related reads; do not assume an existing reporting or coverage key grants it.
- Read availability of combo under the issued credential must be checked. Customer PII is unnecessary for the initial lock import and should not be requested.
- Lock Search does not document pagination, a complete-result count, delta cursor, updatedAt or a rate limit. Confirm full enumeration for more than 1,000 locks and a safe polling cadence. The interactive reporting tool's 1,000-row result cap is another reason not to treat it as the runtime import transport.
- Physical color, lock assignment purpose, full historical assignment/audit events, and lock-specific update webhooks are not confirmed on the documented Lock Search contract.
- Ten facilities currently return zero lock rows. That is not proof they have no physical locks; verify roster/source coverage before requesting any manual setup.
- Two tenant-held locks need maintenance, and the app cannot currently represent tenant-held source status. Preserve these distinctions.
- No integration, import job, facility creation, inventory mutation, credential copying or Cubby write-back was implemented during this investigation.

## Recommended next gate
Approve Cubby as the source of truth and settle faithful tenant-held/unresolved-assignment representation. Obtain/validate the narrowly scoped server-side read access and enumeration behavior. Then implement the staged dry run and show its complete reconciliation before any inventory apply. Continue to prohibit Cubby write-back unless separately approved.

