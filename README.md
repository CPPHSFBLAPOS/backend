# CPPHS FBLA Store: backend

The database, its rules, and the server functions for the CPPHS FBLA school store app. The React app lives in [`CPPHSFBLAPOS/frontend`](https://github.com/CPPHSFBLAPOS/frontend). Daily operations (opening the store, closing a shift, restoring after a pause, adding members) are in [RUNBOOK.md](RUNBOOK.md). The full spec is [docs/SPEC.md](docs/SPEC.md).

```
supabase/
  migrations/   one file per change; never edited after merge
    ..._foundation.sql   members, roles, products, stock ledger, hash-chained log, imports
    ..._preauth.sql      the pre-auth form, Sam's Club listings, signatures, receiving
    ..._gift_cards.sql   cards and their ledger
    ..._register.sql     shifts, sales, voids, refunds, handoffs, outage entries
    ..._reports.sql      every report number, computed in SQL
    ..._storage.sql      private buckets for receipts, signatures, outage sheets, PDFs
    ..._first_admins.sql the two Super Admins who can add everyone else
    ..._catalog.sql      products with on-hand counts for the register (without exposing the ledger)
    ..._deploy_hardening.sql  explicit read grants, PIN hashes and gift card codes kept private, paste lookups
    ..._review_fixes.sql      retried card sales keep their codes, pastes always read, sign-in links follow email
    ..._retry_followups.sql   client ids stay private; retries answer with the change due
    ..._open_signup.sql       anyone can sign in as a Cashier; Super Admins manage members; deactivating blocks
  tests/        pgTAP: permissions, the append-only log, RPC rules, report math
  seed.sql      made-up people and products for local development
netlify/
  functions/    health, sams-lookup, notify, preauth-pdf, daily-reminders (scheduled)
  lib/          shared code: auth, email, Sam's Club parsing, PDF drawing, ROI math
scripts/
  import-base44.ts     one-time import of Base44's CSV exports
  db/test-plain.sh     run the database tests without Docker
tests/          Vitest unit tests, plus tests/concurrency (two registers at once)
```

## How it fits together

- The browser talks to Supabase directly for sign-in, reads (through row-level security), uploads, and every change, which is always a Postgres function (RPC). Each RPC checks the caller's role with `can(action)`, does its work in one transaction, and writes a `log_entries` row in that same transaction.
- `log_entries` is append-only and hash-chained. `verify_log()` rechecks the numbering and every hash.
- Netlify Functions only do what needs a secret key or an outside service: the Claude API lookup, Resend email, PDF drawing, and the daily overdue check. They verify the member's token and call Supabase with it, so the same rules apply.
- The frontend site proxies `/api/*` to this site, so the browser only ever talks to one origin.

## Set up

1. Install Node.js 22+, Docker Desktop, and the Netlify CLI (`npm i -g netlify-cli`).
2. `npm install`
3. `npx supabase start` (first run downloads the images), then `npx supabase db reset`.
4. `cp .env.example .env` and fill in `SUPABASE_URL` and the keys printed by `supabase start`. `ANTHROPIC_API_KEY` and `RESEND_API_KEY` can stay empty until you need the lookup and email; without Resend, emails are logged instead of sent.
5. `netlify dev` serves the functions at http://localhost:8888.
6. Run the frontend (see its README); it signs in against the local Supabase. Sign-in codes show up in Mailpit at http://localhost:54324.

Local test people (all made up), with their register PINs:

| Email | Role | PIN |
| --- | --- | --- |
| advisor@example.com | Advisor | 1111 |
| treasurer@example.com | Treasurer | 2222 |
| cashier@example.com | Cashier | 3333 |
| cashier2@example.com | Cashier | 4444 |
| register@example.com | Register account | none |
| depedros@cppasd.com | President, Super Admin | 5555 |

## Tests

```sh
npm run typecheck && npm run lint
npm test                 # Vitest: money, ROI, CSV, Sam's Club parsing, PDF, function handlers
npm run test:db          # pgTAP through `supabase test db`
npm run test:concurrency # needs the local database running
```

No Docker? `npm run test:db:plain` builds a throwaway Postgres 15+ cluster, loads `scripts/db/supabase-shim.sql` (the few Supabase pieces the migrations use), the migrations and the seed, and runs the same pgTAP files. It needs pgTAP installed into that Postgres. `KEEP=1 npm run test:db:plain -- --no-tests` leaves it running for `npm run test:concurrency`.

## Deploying

Do these in order. Steps marked "check" catch the mistakes that are easy to make and hard to spot later.

1. **Branches.** In both repos, create `main` from the current work and make it the default branch (GitHub > Settings > General > Default branch). Netlify uses the default branch as production, and CI only runs on `main` and pull requests.
2. **Names.** Pick the two Netlify site names now, so each site knows the other's address before its first deploy: for example `cpphs-fbla-store` (the app) and `cpphs-fbla-store-api` (this repo). The app's address is then `https://cpphs-fbla-store.netlify.app`. If you pick a different API name, put its address in the frontend's `netlify.toml` before deploying the frontend: the frontend forwards members' sign-in tokens to that address.
3. **Supabase project** (US East). `npx supabase link --project-ref <ref>`, then `npx supabase db push`. This applies every migration, including the two first Super Admins. `seed.sql` is never pushed.
   - Check, in the SQL editor: `select has_table_privilege('authenticated', 'public.settings', 'select');` returns `true`. New projects grant nothing by default; the migrations grant reads explicitly.
4. **Supabase dashboard.** Set these by hand. Do not run `supabase config push`: `config.toml` holds localhost URLs and would overwrite the production ones.
   - Authentication > Sign In / Providers > Email: **Email OTP Length 6** and **Email OTP Expiration 600** seconds (the email says 10 minutes). Leave **Confirm email** and **Secure email change** on. The sign-in screen accepts 6 to 10 digits, so a length mismatch will not lock anyone out, but the email text says 6.
   - Authentication > SMTP: Resend (`smtp.resend.com`, port 465, user `resend`, password = Resend API key), sender on the chapter's verified domain.
   - Authentication > Email templates: paste `supabase/templates/sign-in-code.html` into Magic Link and Confirm signup, so emails carry the code.
   - Authentication > Hooks: enable "Before User Created" with the Postgres function `public.hook_before_user_created`.
   - Authentication > URL configuration: the app's address as Site URL.
   - Project Settings > API Keys: new projects have a **Publishable key** (`sb_publishable_...`) and **Secret keys** (`sb_secret_...`) instead of the older anon and service_role keys. Wherever this repo says anon key, use the Publishable key; wherever it says service role key, use a Secret key.
5. **Netlify, this repo.** Create a site from this repo on the chapter's team with the name from step 2, production branch `main`, deploy previews on, branch deploys off. Before the first deploy, add the variables from `.env.example` (Add environment variables on the setup screen), scoped to Functions:
   - `SUPABASE_URL`, `SUPABASE_ANON_KEY` (Publishable key), `SUPABASE_SERVICE_ROLE_KEY` (a Secret key);
   - `ANTHROPIC_API_KEY`, with a monthly spend limit set in the Anthropic console;
   - `RESEND_API_KEY` and `EMAIL_FROM` on the verified domain;
   - `APP_URL` = the app's address from step 2 (email links point there);
   - leave `ALLOWED_ORIGINS` unset.

   Functions only see the variables that existed when they were deployed. If you add or change one later, redeploy (Deploys > Trigger deploy > Deploy site; 15 credits). `daily-reminders` runs every day at 12:00 UTC.
6. **Netlify, the frontend.** See its README.
   - Check, on the app's production address: `/api/health` returns `{"ok":true,...}` with every `configured` flag true. Then sign in as a real member with an emailed code and run one Sam's Club lookup.
7. Add the repository secrets for the weekly backup (`SUPABASE_DB_URL`, `BACKUP_PASSPHRASE`) if the store stays on Supabase Free.

## Importing from Base44

Export Base44's products, sales and gift cards as CSV, then on an admin's own machine:

```sh
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<key> \
  npm run import:base44 -- --products products.csv --sales sales.csv --gift-cards gift-cards.csv
```

Products whose SKU already exists are skipped, so it is safe to run twice. Sales go into `legacy_sales`; the old customer field is kept only as a short note. Gift cards with money left come over as Import transactions dated today. Officers can also import products and sales from the Inventory screen.
