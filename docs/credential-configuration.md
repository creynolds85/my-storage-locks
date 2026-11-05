# Credential roles and secure entry

Verified against Cubby's current data dictionary, published schema.csv and Operator API reference on November 5, 2026. The provider's onboarding email identifies BigQuery project `cubby-partner-data`, dataset `analytics`.

| Function | Credential / source | Limits |
|---|---|---|
| Initial facilities, unit IDs/names, physical lock IDs/serials, source assignments/statuses, maintenance and source timestamps | Cubby BigQuery service-account JSON; organization-scoped reads of analytics.facilities, units and door_locks | Published schema includes these fields. Actual key permissions/visible rows must be tested after secure entry. |
| Existing lock combinations | Secure **one-time Cubby lock export** or another specifically authorized source that includes combinations | Current BigQuery door_locks and door_lock_history documentation explicitly exclude combinations. An Operator API key is not proof of a lock-secret export endpoint. |
| Historical/current reporting on availability, leases, contacts, balances, payments, delinquency and exemptions | BigQuery JSON, where these tables/fields are granted | The documentation describes default refresh schedules, not a measured universal cadence. Actual per-table source-event-to-visibility latency still needs testing under this key. One-minute polling is retained; no unverified warehouse result authorizes sending a combination. |
| Fresh lease/unit/tenant identity, compliance, balance/payment/auction and approved exemption checks immediately before SMS | Separate **Cubby Operator API key** with read-only Search role, allowed facilities and PII access | Verify actual API responses, all access restrictions, pagination, incremental behavior, rate allocation and customer authorization. Warehouse credentials do not authenticate this API. |
| Immediate event notification | Cubby-configured webhook subscriptions plus verified webhook authentication or an authenticated relay | The Operator key alone neither registers subscriptions nor proves incoming event authenticity. Confirm a clearance event independent of Cubby's physical lock module. |
| SMS API calls | Restricted Twilio API Key SID + secret in the **My Storage Locks subaccount** | Message create/read/list only. No MSP parent credentials. |
| Twilio callback signature verification | **My Storage Locks subaccount Auth Token** | Server-only full subaccount credential; used to verify signed callbacks. Never place it in browser code or logs. |
| Actual SMS sender | Dedicated Messaging Service SID plus a registered phone number/sender | A Messaging Service and API key alone do not provide an approved sender. |

## Verified warehouse versus reporting connector

The connected Cubby reporting interface previously exposed a combination field. That does not establish what the user's BigQuery key can retrieve. The published BigQuery schema has door_locks fields including door_lock_id, serial_code, facility_id, unit_id, unit_name, status, is_needs_maintenance, custom_location, created_at and updated_at, and **no combination column**. The live credential verifier inspects INFORMATION_SCHEMA under the actual credential and reports whether that column exists, rather than assuming equivalence.

The verifier uses only read queries, explicit `org_id` parameters, a 100 MiB maximum billed-bytes limit per query, no query cache and classified errors. It returns schema availability and redacted counts, not combinations, private keys or tenant rows. Source record updated_at is expressly not treated as an ETL refresh watermark. A missing/malformed credential fails closed. It never writes production inventory or enables SMS.

## Enter the BigQuery key directly in Vercel

1. Open the My Storage Locks project's **Settings → Environment Variables**: https://vercel.com/my-storage-ops/my-storage-locks/settings/environment-variables . Confirm the project is `my-storage-locks`, not MSP.
2. Choose **Add Environment Variable**, type **Secret**, environment **Production only**.
3. Key: `CUBBY_BIGQUERY_SERVICE_ACCOUNT_JSON`.
4. Open the original service-account JSON file locally and paste its complete, unmodified JSON directly into Vercel's secret Value field. Keep its normal JSON escaping for the PEM private_key. Do not paste it into ChatGPT, a GitHub file/issue/comment, `.env.example`, or a public/client environment variable. Do not change it into a filesystem path; the server parses JSON from this variable.
5. Save. The nonsecret configuration is already staged: `CUBBY_BIGQUERY_PROJECT_ID=cubby-partner-data`, `CUBBY_BIGQUERY_DATASET=analytics`. The existing `CUBBY_ORGANIZATION_ID` scopes all data reads. If Cubby specifies a dataset region, set `CUBBY_BIGQUERY_LOCATION` to that value.
6. Redeploy production once to make new secrets available. The protected `POST /api/integrations/cubby/warehouse/verify` uses the existing worker authorization; no secret is supplied in its URL/body. The administrator can invoke it through the existing server-to-server worker mechanism. Do not make this endpoint public to simplify testing.
7. Read the credential-specific result: authorized tables, expected lock columns, actual lock count/status totals, duplicate identities and combination-column presence. This is connection/reconciliation verification, not the production import.

If Google returns permission denied, ask Cubby to confirm BigQuery read access on the authorized dataset/views and query-job creation on the stated billing project (normally Data Viewer and Job User-equivalent permissions). Do not grant Owner/Editor or source write privileges. Keep scope limited to this organization's data. No extra Google API key is needed for service-account authentication.

## Enter the separate Cubby Operator credential

Use the same Vercel project, type **Secret**, **Production only**, key `CUBBY_API_KEY`. Enter only the issued Operator API key, not the BigQuery JSON, service-account email or Google access token. Request read-only Search access plus PII/contact preferences and compliance access, and verify the actual operational surfaces including `delinquency-exemptions/search` for waiver evaluation.

Keep `CUBBY_OPERATIONAL_ACCESS_VERIFIED`, `CUBBY_RATE_LIMIT_VERIFIED` and `CUBBY_WEBHOOK_AUTH_CONFIRMED` false/unset until verified. Enter a dedicated `CUBBY_WEBHOOK_SECRET` only after Cubby/relay authentication is established; its value is not assumed to equal the Operator API key.

Keep `LOCKS_LIVE_SMS_ENABLED=false`, `TWILIO_SENDER_VERIFIED=false`, `TWILIO_BODY_REDACTION_VERIFIED=false` and database live-release latches off until their respective checks pass. Do not turn those flags on merely because credentials have been entered.

## Completed production inventory migration

The approved one-time export was imported on November 5, 2026: **23 facilities, 1,146 locks, 1,146 encrypted combinations and 630 current unit assignments**. A separate verification pass matched all 1,146 records and codes exactly, with zero conflicts or duplicates. All 15 multi-lock units were retained. No Operator API credential was needed for this migration. Source identifiers, raw/display statuses, available source timestamps, maintenance information and original updater labels were preserved. Unknown actors/dates/colors were not fabricated. Migration execution is now closed and its temporary application entry point removed.

See `production-inventory-verification.md` for the reconciled counts and actual website checks. Freshness research and live SMS activation remain separate.

Sources: https://cubbystorage.github.io/docs/data-dictionary/ ; https://cubbystorage.github.io/docs/data-dictionary/schema.csv ; https://cubbystorage.github.io/docs/api/ ; https://cubbystorage.github.io/docs/make-webhooks/ ; https://docs.cloud.google.com/bigquery/docs/authentication .
