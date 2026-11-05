# Production inventory verification — November 5, 2026

Production: https://mystoragelocks.com · Supabase project `diffajehdruacwismnyk`.

The approved snapshot contained 23 facilities and 1,146 locks. Authenticated administrator dry run: 1,146 checked, zero conflicts. Import: 1,146 inserted and encrypted round trips verified. Independent verification: 1,146 existing matches, 1,146 exact combination matches, zero inserted records, zero conflicts. Snapshot SHA-256: `1e60d8ef4cdf7083d46ce85c229e6612bbfe91539ef9e7456ee50c59a1b96928`.

| Production result | Count |
| --- | ---: |
| Facilities, all with source addresses and immutable source mappings | 23 |
| Locks and encrypted combinations | 1,146 each |
| Available | 482 |
| Vacant assignments | 556 |
| Overlock assignments | 16 |
| Auction assignments | 8 |
| Unclassified assignments | 43 |
| Tenant-held | 5 |
| Maintenance | 2 |
| Missing | 24 |
| Damaged | 10 |
| Active unit assignments, including tenant-held/maintenance | 630 |
| Units with multiple locks | 15 |
| Duplicate source IDs / invalid facility references / import conflicts | 0 each |

All source serials and combinations were retained exactly, including leading zeros and the one nonstandard format. All 1,146 source creation/update timestamp pairs were preserved. Imported assignment actor/date remain null because the source did not establish them. Physical color is Unknown. No employee memberships were created. Existing administrator access and facility-level RLS remain in force.

## Production website checks

The existing Cody administrator account signed in through the secure login flow. The real website shows all 23 facilities, Total 1,146, Available 482, Overlocked 16, Vacant 556, Auction 8 and Missing/Damaged 34. Additional informational counts and filters expose 43 unclassified, five tenant-held and two maintenance records. Case-insensitive serial search returned the correct lock. Authorized combination reveal matched the frozen export; separate browser checks confirmed exact leading-zero and nonstandard-format values without outputting codes. The edit panel accepts Unknown physical color and exposes existing local lock workflows. Database calls under the live administrator's authorization verified classification, recovery and local reassignment inside a rolled-back transaction; source assignments were not altered by testing.

The initial schema/access-control acceptance script passed. All 48 automated tests and the production build passed. The migration token is closed and execution grants revoked after reconciliation; the one-time controls are removed from normal administration.

## Operational data freshness — limits of current evidence

The BigQuery JSON credential and Operator API key are not configured in the production environment at verification time. Consequently actual Google BigQuery source-event-to-query-visibility latency has **not** been measured under that credential. The connected Cubby reporting interface provided different per-table captions in the same observation window: contacts “As of Nov 5, 9:40 PM UTC”, payments “As of Nov 5, 9:54 PM UTC”, units “As of Nov 5, 9:55 PM UTC”, leases “As of Nov 5, 10:00 PM UTC”. These captions do not prove when a specific source event became query-visible and are not substitutes for a Google BigQuery connection test.

The supplied October 22 evidence shows a coverage source event at 10:56:54 EDT, table refresh at 11:00:38 EDT (3m44s later), and confirmed query visibility by 11:07:05 EDT (10m11s after the event). It rules out using a universal hourly assumption, but does not establish payment-clearance, rental, unit, overlock or contact latency. The verifier now distinguishes the published default from unmeasured actual cadence. An Operator API key is not required solely because of that default; sufficiently fresh, complete, authenticated authorization evidence must be demonstrated before any disclosure.

The unattended one-minute worker remains enabled. No successful operational synchronization has yet been recorded. Live combination SMS remains disabled in both environment configuration and database release settings. No migration action sent an SMS or modified the MSP Twilio configuration.
