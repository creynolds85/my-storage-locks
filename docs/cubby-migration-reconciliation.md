# One-time inventory migration: structural dry run

2026-11-05, reporting source: **As of Nov 5, 7:40 PM UTC** for door_locks and facilities; **As of Nov 5, 7:55 PM UTC** for units. Read-only structural reconciliation; no production lock/facility/assignment/combination writes.

| Check | Result |
|---|---:|
| Physical source locks | 1,146 |
| Facilities with lock inventory | 13 |
| Missing source ID/serial/combination | 0 |
| Duplicate source IDs | 0 |
| Duplicate facility + case-insensitive serial | 0 |
| Unmatched facility references | 0 |
| Unmatched non-null unit references | 0 |
| Units containing multiple physical locks | 15 |
| AVAILABLE | 480 |
| ACTIVE | 625 |
| IN_TENANT | 7 |
| MISSING | 24 |
| DAMAGED | 10 |

Status counts changed from the earlier 479/626 while Cubby remains in use. Reconcile a fixed export at migration time; do not assume the earlier counts are a frozen snapshot. A unit is not a unique lock identity. Preserve all locks on the 15 multi-lock units.

The destination had zero physical locks/facilities at this check. No existing records were overwritten. Serial numbers and combinations must remain exact strings, including leading zeros. A reporting aggregate confirms required values and references; it is **not** an encrypted frozen migration export or an applied import.

## Remaining migration decisions and safeguards

- Preserve Cubby organization + door_lock_id as immutable source identity; facility_id and unit_id remain source references with explicit local mappings. Automatically match facilities by source ID, never by fuzzy name alone. Existing facilities can be represented by all 23 Cubby facility records, including the 13 with locks.
- Preserve raw source status, maintenance flags, custom location and timestamps alongside local physical purpose. Physical color is not exposed in the reporting lock fields; do not infer color from purpose.
- ACTIVE does not distinguish overlock, vacant or auction purpose. IN_TENANT is physically tenant-held and must not become Available. The current local schema needs a reviewed unavailable/unclassified or tenant-held representation before importing these records. Do not misclassify them merely to satisfy the current status enum.
- Retain historical source data without continually overwriting local assignments/statuses. Runtime integration does not read Combo Locks.
- `scripts/cubby-migration-dry-run.mjs PRIVATE_SNAPSHOT.json [PRIVATE_EXISTING.json]` performs read-only identity/conflict checks and prints no combinations. It deliberately has no apply transport. Run against the frozen secure export and actual destination before writing; reject duplicates and conflicting existing secrets/assignments.
- A production importer must add source mapping/provenance and staging, calculate a reviewed proposal, use a single atomic transaction with insert-only conflict rejection, and produce counts/hashes without codes. Reruns must skip verified identical source records and stop on conflicts. That apply path is not yet enabled.

Next step: obtain the secure complete export, confirm physical-purpose/tenant-held representation and review record-level reconciliation. Only then apply the one-time migration. No manual employee recreation of the 1,146 locks is planned.
