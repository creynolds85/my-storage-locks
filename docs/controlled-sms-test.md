# Single-recipient controlled SMS test

The existing isolated Huntersville/1034 fixture is held encrypted in the private
`automation.controlled_sms_test` record. It does not reference or change real
tenants, balances, inventory, assignments or combinations. Its recipient and
message digest are pinned in the final Twilio transport boundary.

`POST /api/automation/controlled-test` uses the existing worker authentication.
`{"operation":"inspect"}` returns redacted preparation state without disclosure
or provider submission. It accepts no destination, message or fixture override.

No send is authorized by deployment. A future explicitly approved execution
requires both `LOCKS_CONTROLLED_SMS_TEST_ENABLED=true` and a separately recorded
`send_approved_at` / `approval_expires_at` window of at most 15 minutes. Keep
`LOCKS_LIVE_SMS_ENABLED=false`, database mode `dry_run`, and general/tenant
activation approvals unset. No API operation grants the test approval.

Before reserving the single attempt, dispatch verifies the dedicated service,
approved A2P campaign and sole owned SMS-capable sender. The database claim
rechecks the fixed recipient, original disposable payload, test-only consent,
approval and STOP suppression. The final provider boundary independently checks
the exact authorized number and body hash. Altered or other destinations fail
closed. The shared Twilio transport requests discarded message bodies and uses
the existing signed callback route with `controlled=1` to record private status.

A reserved, failed, submitted, delivered or uncertain attempt cannot be claimed
again. Reconcile an uncertain outcome before any separately authorized new test;
there is no automatic resend or promotion of this fixture to tenant messaging.
