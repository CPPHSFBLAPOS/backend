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

1. Create the hosted Supabase project (US East). Link and push: `npx supabase link --project-ref <ref>` then `npx supabase db push`. This applies the migrations, including the two first Super Admins. `seed.sql` is never pushed.
2. In the Supabase dashboard:
   - Authentication > SMTP: Resend (`smtp.resend.com`, port 465, user `resend`, password = Resend API key), sender on the chapter's verified domain.
   - Authentication > Email templates: paste `supabase/templates/sign-in-code.html` into Magic Link and Confirm signup, so emails carry the 6-digit code.
   - Authentication > Hooks: enable "Before User Created" with the Postgres function `public.hook_before_user_created`.
   - Authentication > URL configuration: the frontend's production URL.
3. Create a Netlify site from this repo (on the chapter's store team). Set the variables from `.env.example`, scoped to Functions. Deploys publish the functions; `daily-reminders` runs every day at 12:00 UTC.
4. Point the frontend's `netlify.toml` `/api/*` proxy at this site's URL.
5. Add the repository secrets for the weekly backup (`SUPABASE_DB_URL`, `BACKUP_PASSPHRASE`) if the store stays on Supabase Free.

## Importing from Base44

Export Base44's products, sales and gift cards as CSV, then on an admin's own machine:

```sh
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<key> \
  npm run import:base44 -- --products products.csv --sales sales.csv --gift-cards gift-cards.csv
```

Products whose SKU already exists are skipped, so it is safe to run twice. Sales go into `legacy_sales`; the old customer field is kept only as a short note. Gift cards with money left come over as Import transactions dated today. Officers can also import products and sales from the Inventory screen.
