# Action Items during parallel testing

The manager dashboard no longer mounts the Action Items component or makes its polling requests. Inventory summaries, serial search, and Walk-Through remain unchanged.

`automation.lock_mirror_control.action_items_enabled` defaults to false and is writable only through existing backend administration. Task generation requires both this explicit activation switch and `mode = 'msl_authoritative'`. Mirror Mode always disables it; changing authority alone cannot activate tasks or surface historical alerts. Future activation requires a separate decision about eligible new conditions and historical records, plus deliberate restoration of the manager UI.

A database trigger suppresses all new Action Items, conflict upserts, and attempts to reopen resolved historical items while disabled. It covers automation, missing assignments, synchronization warnings, notification reviews, and direct Walk-Through issue inserts. Suppression emits a minimal restricted database log containing only the task kind, never notes or combinations. Existing mirror/reconciliation records, synchronization state, notification records, inspection findings, and inspection events continue to retain detailed diagnostics.

Historical Action Items are not deleted. Manager RLS and the legacy dashboard RPC return no items; the legacy action RPC refuses resolution/recovery through this disabled feature. Authorized backend tools retain existing access. Normal inventory assignment/release workflows and unit-card issue indicators are separate and unchanged.

Focused checks: `tests/action-items-mirror.test.mjs` checks removal of the manager component while retaining summaries/search/Walk-Through. `tests/action-items-mirror.acceptance.sql` runs only inside a rolled-back transaction, covering task/reopen suppression, historical retention, issue/confirmation/audit persistence, scoped authorization, explicit future activation boundaries, and unchanged inventory/synchronization functions.
