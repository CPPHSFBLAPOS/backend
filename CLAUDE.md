# CPPHS FBLA Store App: backend

Point of sale and back office for the Corning-Painted Post High School FBLA school store: register and cash shifts, inventory, Sam's Club pre-auth purchasing with signatures, gift cards, an append-only transaction log, and Treasurer reports.

This repo is the backend: the Supabase database (migrations, RPCs, RLS, pgTAP tests) and the Netlify Functions. The React app is in `CPPHSFBLAPOS/frontend`.

Full spec: `docs/SPEC.md`. Read the section for your task before planning.

## Stack
- Supabase: Postgres with row-level security, Auth with email one-time codes, Storage.
- Netlify Functions in `netlify/functions` (Node, TypeScript), shared code in `netlify/lib`. This is its own Netlify site; the frontend site proxies `/api/*` to it.
- Email: Resend. Sam's Club lookup: Claude API, called only from the `sams-lookup` function.

## Commands
- `npx supabase start`, then `npx supabase db reset`: local database with all migrations and `supabase/seed.sql`
- `netlify dev`: functions at http://localhost:8888/.netlify/functions/<name>
- `npm run typecheck` and `npm run lint`
- `npm test`: Vitest unit tests
- `npm run test:db`: pgTAP database tests (`supabase test db`)
- `npm run test:db:plain`: the same tests on plain Postgres with `scripts/db/supabase-shim.sql`, for machines without Docker
- `npm run test:concurrency`: two registers at once against a running database

## Rules that must never break
- IMPORTANT: Money is integer cents (`bigint` in Postgres, a number of cents in TypeScript). Never floats. Format only for display.
- Every write that touches money, stock, approvals, or access is a Postgres function called over RPC. It checks the caller's role (`private.require(action)` / `public.can(action)`), runs in one transaction, and writes its `log_entries` row (`private.write_log`) in that same transaction. The browser never inserts or updates tables directly.
- `log_entries` is append-only. Never write UPDATE or DELETE against it, and never change old rows in a migration. Fix mistakes with a new reversing entry.
- Stock on hand is the sum of `stock_movements`. Gift card balance is the sum of `gift_card_txns`. Never add an editable stock or balance column.
- `sale_lines.unit_cost_cents` is saved at the moment of sale. Reports use it, never the product's current cost.
- Nothing is deleted. Archive products; void or refund sales.
- Every new table or view gets RLS enabled (views: `security_invoker`), explicit read policies, and `grant select on public.<name> to authenticated, service_role;` in the same migration. Hosted projects no longer grant table privileges by default, and the plain-Postgres shim matches that. No write policies or write grants. Never grant a secret column: `members` uses column grants so `pin_hash` stays unreadable.
- Only email-code sessions are members: `current_member_id()` ignores password sessions. Keep that check if you replace the function.
- RPCs are `security definer` with `set search_path = public, pg_temp`. Internal helpers live in the `private` schema, which the API cannot call.
- An RPC that checks a PIN must return a jsonb error (not raise) after a wrong PIN, or the failed-try counter rolls back.
- Netlify Functions verify the caller's Supabase token and call Supabase with it (`getCaller`). Only scheduled functions use the service role key.
- Never store a buyer's name. Never send student data to the Claude API.
- Pre-auth limits come from `settings`: $300 per form, receipt due 5 days after purchase.

## Workflow
- One migration per change in `supabase/migrations`. Never edit a migration after it merges. End each migration with the grant/revoke block the others use.
- Money logic ships with tests: Vitest for math, pgTAP for RPCs and RLS.
- When you finish a change, run typecheck, lint, `npm test`, and `npm run test:db`, and show the output.
- Work on a branch per phase and open a PR into `main`.
- Ask before adding a dependency.

## Gotchas
- Time zone is America/New_York. Store `timestamptz`; school-day logic uses `private.local_today()` / `private.local_date()`. Netlify scheduled functions run on UTC cron.
- pgTAP files: psql variables are not substituted inside `$$ ... $$`; build the SQL with `format(..., :'var')`.
- Uploads go straight from the browser to Supabase Storage. Function request bodies are capped at 6 MB.
- Each production deploy uses 15 of Netlify's 300 free monthly credits. Test on deploy previews and deploy production about once a week.
- The school year runs September 1 to June 30.
- Supabase Free pauses a project after a week without activity. If the hosted project stops answering, check that first.
