# Tenant combination requests

`/get-combination` uses the existing private automation worker, durable event inbox,
notification outbox, eligibility policy, encrypted inventory, Twilio sender,
delivery callbacks and recovery tasks. The login page links to it. Production
starts in a clearly labeled non-disclosing testing state.

The submitted phone only matches the verified rental phone; it never becomes an
independent authorization factor or delivery destination. No combinations or
account-dependent results are returned by the public API. Unit input is encrypted;
phone/IP rate keys are hashed. Source snapshots, exact assignment and combination
version, verified consent, suppression and approvals are rechecked before dispatch.
Unknown provider outcomes block another submission until reconciled. Physical
assignments stay in place; repeated requests share their recovery task.

Durable limits: 6 requests/IP/15 minutes, 24/IP/day, 3/phone/30 minutes,
3/unit/30 minutes, 10-minute unit/phone cooldown, 40 total intakes/minute.
Signed single-use challenges expire after 30 minutes; accepted requests expire
after 15 minutes. Source verification is capped at six requests/minute with a
reserved immediate pre-dispatch revalidation. Existing automatic events retain
priority and the one-minute worker schedule remains unchanged.

## Verification and release state

Thirteen controlled Node tests and transaction-rolled-back database acceptance
checks cover authorization, current assignments, stale data, repeats, rate limits,
consent, suppression, changed combinations, provider failures/unknown outcomes,
after-hours operation and shared recovery. Disposable codes and stub senders are
used. These checks do **not** establish real Cubby event latency or carrier delivery.

As of November 6, 2026 UTC, production remains `dry_run`, with general live SMS
disabled and tenant-request approval unset. The dedicated Twilio service authenticates
successfully but has no sender. There are no verified consent records. The current
operational adapter still lacks verified Cubby API access. BigQuery is readable,
but sampled event visibility upper bounds of about 44 and 56 minutes cannot support
a claim of immediate authorization. The freshness monitor continues independently.

Final controlled carrier acceptance requires a registered dedicated sender,
verified current source access and business release rules, an approved test
recipient represented by a controlled authorized rental/consent record, and a
disposable combination. General tenant messaging requires acceptance results and
explicit approval of conditions/templates; tenant requests also require the
separate `tenant_requests_approved_at` latch. Do not turn on flags merely to test
the public form, invent consent, or redirect real tenant messages to a test phone.
