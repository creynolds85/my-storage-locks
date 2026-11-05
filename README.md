# Lock Manager
Independent Next.js / Supabase application for Storage Operations Specialists LLC. Production domain: https://mystoragelocks.com.
MSP infrastructure is not used.

## Development
Copy .env.example to .env.local with this project's URL and publishable key. Run npm ci, npm run dev.
Run npm test and npm run build before release.
Database schema and acceptance SQL are tracked in supabase/. All mutations are transactional RPCs; database policies enforce active accounts, live sessions, and facility memberships. Combination ciphertext and encryption keys are in a private schema. Audit events never contain combination values.
No sample inventory is seeded in production. Test SQL runs in a rollback-only transaction.
GitHub repository must be a separate private repository named my-storage-locks.
