# Independent inventory and Cubby operational integration

Updated November 5, 2026. The user confirms continued normal Cubby operations excluding the paid Combo Locks tab. My Storage Locks is the independent physical inventory authority. Integration infrastructure is implemented in dry-run mode; live tenant SMS and inventory migration remain gated.

| Data/action | Authority |
|---|---|
| Physical inventory, combinations, assignments, release and recovery | My Storage Locks |
| Facilities, units, leases, move-ins, account/payment facts and authorized tenant | Cubby operational API |
| Original lock IDs, source statuses and timestamps | Immutable one-time migration provenance |
| Consent evidence, suppression, notification deduplication and recovery tasks | My Storage Locks, with Cubby/Twilio restrictions |
| Carrier delivery result | Twilio; never a physical recovery signal |

The existing website is retained. Cubby Combo Locks is not read during normal operation. There is no Cubby write-back. Local assignment, release, inventory edits and combination lookup continue during integration outages.

See [the implemented workflows, draft rules/templates and controlled activation checklist](automation-implementation.md) and [the latest migration structural reconciliation](cubby-migration-reconciliation.md).

Remaining genuine requirements: a dedicated deployable Cubby operational credential with PII/compliance/ledger/payment/auction permissions; verified rate/completeness and authenticated webhook contracts; a separate My Storage Locks Twilio Messaging Service; verified scoped tenant messaging consent; facility/physical-unit mappings and return instructions. Commercial access to normal Cubby functions is accepted as confirmed and is not a new licensing question.

Complete a secure frozen export, resolve ACTIVE/tenant-held classification and perform record-level insert-only reconciliation before production migration. After actual API/provider configuration, run one focused controlled-recipient E2E test, then obtain explicit approval of final release rules and templates before enabling live notifications. No manager is required for eligible events after approved activation.
