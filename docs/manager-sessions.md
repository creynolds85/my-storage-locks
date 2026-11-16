# Manager session limits

Manager access is limited to 30 minutes without verified interaction and 12 hours from the original Supabase `auth.sessions.created_at`. The existing `private.live()` gate enforces both limits for RLS reads and manager RPCs. Dashboard rendering and manager-authenticated walkthrough refresh also check the server session. Worker credentials and public tenant requests are separate and unchanged.

A private, session-keyed activity timestamp changes only through explicit foreground interaction calls. Trusted pointer, keyboard, touch and wheel input count, including walkthrough confirmations. Opening/resuming a page, minute polling, synchronization, and Supabase token rotation only read status. Expired sessions cannot be revived by activity calls. Unknown historical activity falls back to the original sign-in timestamp, requiring older sessions to reauthenticate on rollout. Other active tabs can share the server-recorded activity; no browser clock or local-storage timestamp grants access.

The client checks server status, applies server-derived monotonic deadlines, clears manager state and auth storage on expiry, and replaces the page with `/login?expired=1`. The login page shows a plain expiration message. Normal sign-out retains the existing global Supabase sign-out behavior. No employee permissions, inventory, Cubby polling, or SMS settings change.

Focused checks: `tests/manager-session.test.mjs` and the transaction-rollback-only `tests/manager-session.acceptance.sql`. The database fixtures verify active walkthrough persistence, unchanged inactivity on background reads/token refresh, denied expired RLS/RPC access, absolute expiry, no expired-session revival, and private table/function permissions.

Explicit owner-authorized inspection resets retain the entire deleted week, entries and events in `private.walkthrough_reset_archive`, inaccessible to employee roles. Resetting an inspection does not erase independently actionable issue tasks or physical inventory.
