# Release 1 acceptance
- Production build: passed (Next.js 16.4.5 / Node 24), including TypeScript.
- Six CSV validation tests passed.
- Database acceptance passed in a rollback-only transaction: administrator visibility; employee facility RLS; seven substring patterns; leading zeros; facility-scoped duplicate serials; all twelve physical-color/assignment-type combinations; unit strings; returns and assignment history; optimistic edit conflicts; combination reveal/correction and audit redaction; private-table denial; direct-write denial; atomic import and duplicate preview; aggregate counts; revoked-session denial.
- Browser UI acceptance passed at 1440x1000 (administrator) and 390x844 (employee): sign-in UI, search requests from first character, no horizontal overflow, reveal/copy, assignment, return, history, add, CSV import/export, navigation. These browser tests use isolated API fixtures. They do not establish live Supabase password-login or email-delivery acceptance.
- Security advisor: no WARN or ERROR findings. INFO notices identify the three intentionally inaccessible private tables.
- Real end-to-end password login, initial administrator email confirmation, password recovery, and auth redirects require configured Auth URLs and first-account setup.
- Production contains no sample facilities, locks, assignments, or test accounts.

## Initial account
The approved initial administrator email has been configured through an authorized database operation. Use Set up account on the login page, confirm the email, then sign in. Administrators authorize employee emails before employees set up their accounts.

## Hosting setup
Set Supabase Authentication Site URL to https://mystoragelocks.com and add the production origin and its callback paths to allowed redirects. Until DNS is ready, also allow the exact temporary production Vercel origin.
Attach the custom domain in Vercel and configure the registrar DNS using the project-provided recommended records.
GitHub source publication and Git-linked releases require the connected GitHub app to have repository Contents write permission.

## Production smoke result
Production deployment dpl_4m48X1b3nf6uzEWyzcFbDWyuqg2S is READY. https://my-storage-locks.vercel.app loads the actual sign-in screen at 1440px and 390px without page errors or horizontal overflow. /api/health returns 200. Anonymous inventory and combination RPC requests both return 401. No error/fatal runtime logs were found in the post-deployment window. GitHub source commit: 66175c4f49fafd627899f3f499d176b10ad38594. Vercel Git auto-deploy connection remains to be configured in the existing project's Git settings. DNS still points to registrar parking addresses; authentication redirect setup and first real-user login remain unverified.
