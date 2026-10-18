# FBLA Store App Build Blueprint

Oct 14, 2026 · @Shawn

## Start here

Build the store app from scratch with Claude Code: a React frontend and backend functions on Netlify, with the database, sign-in, and files on Supabase. Officers start using the pre-auth after Phase 2, and Base44 keeps ringing sales until the cutover gate after Phase 4.

**Today, in order**

1. Make a GitHub organization for the chapter (for example `cpphs-fbla`) with a private repo named `fbla-store`. Add the Advisor as an owner so the code outlives your graduation.
2. Make a Supabase organization the same way, Advisor as owner and you as a member, then create one project in a US East region.
3. Make a new Netlify team for the store, owned by the Advisor and separate from any personal sites. Every project on a team shares one credit balance and pauses together if it runs out.
4. Pick a domain the chapter controls and verify it in a Resend account. Sign-in codes need it, because Supabase's built-in email only reaches the project's own team, at 2 messages an hour.
5. Email district IT the student-data question from Open items. Their answer decides when officers can use the app with real names.
6. Install Node.js (LTS), Git, Docker Desktop (the Supabase CLI runs the local database in Docker), the Netlify CLI, and [Claude Code](https://code.claude.com/docs/en/quickstart).
7. Clone the repo. Put the file from the CLAUDE.md section at the root as `CLAUDE.md`. Export this doc as Markdown and save it as `docs/SPEC.md`. Commit both.
8. In the repo, run `claude --permission-mode plan`, paste the Phase 0 prompt from Claude Code prompts, read the plan, then approve it.
9. The Anthropic Console account and API key for the Sam's Club lookup can wait until Phase 2. Set a monthly spend limit when you make it.

**How to run each phase in Claude Code**

- Start each phase in a fresh session (`/clear`) and in plan mode (`Shift+Tab` until the status bar shows plan mode). Approve the plan before any code gets written.
- Every prompt ends with tests to run. Ask for the test output as proof, not a summary.
- Before merging, ask: "Use a subagent to review this phase's diff against docs/SPEC.md and report only gaps that break the spec."
- For UI, drag in a photo of the paper form or screenshots of the [pre-auth demo](https://claude.ai/artifact/5tAVi71qArafTWtgHjUSyg) so Claude can match the layout.
- One branch and one pull request per phase. Merge only when CI is green.

## What you're building

One web app that runs the school store register, tracks stock, handles Sam's Club pre-auth purchases with signatures, sells gift cards, and gives the Treasurer and Advisor reports they can trust.

| Part | What it does |
| --- | --- |
| Register | Shifts with a counted drawer, sales, voids and refunds, gift card payments, paper backup when Wi-Fi is down |
| Inventory | Products, prices, stock from a ledger of movements, counts, low-stock alerts |
| Pre-auth | The Preauthorization Purchase Order Form: Sam's Club lookup, ROI, $300 limit, Student and Advisor signatures, receipts due in 5 days |
| Gift cards | Paid and promo cards, split payment, balances owed |
| Transaction log | Every money, stock, approval, and access action, append-only |
| Reports | Dashboard, profit by item, cash over/short, monthly Treasurer Report, year-end report |

**Chain of command.** A student officer fills out and signs the pre-auth. The Advisor is the only approver. Super Admins are depedros@cppasd.com and depedroshawn@gmail.com, plus the Advisor once the app is live.

**Rules every feature follows**

1. Money and stock change only through logged records. Stock is never typed in.
2. Each sale line saves its cost at the moment of sale, so past profit never shifts.
3. Nothing is deleted. Products are archived, sales are voided or refunded, and mistakes get a reversing entry.
4. The drawer is counted when every shift opens and closes.
5. No buyer names are stored. Only officers and members have accounts.
6. Gift card money is owed by the store until it's spent.

**Not in version 1:** card payments, customer accounts, online ordering.

## Tech stack and monthly cost

Netlify hosts the frontend and the backend functions, and Supabase holds the database, sign-in, and files. Everything runs on free tiers except the Sam's Club lookup, which costs a few cents per search.

| Layer | Choice | Why | Cost |
| --- | --- | --- | --- |
| Frontend | React + TypeScript + Vite, Tailwind, installed as a PWA | Your stack. Runs on the store laptop, a Chromebook, or a phone, and can queue sales offline later | Free |
| Hosting and backend functions | [Netlify](https://www.netlify.com/pricing/): the built app plus Node functions in `netlify/functions` | One deploy for frontend and backend code, and every pull request gets a preview link. Functions get [60 seconds](https://docs.netlify.com/build/functions/configuration), enough for the Sam's Club lookup | Free: 300 credits a month. Each production deploy is [15 credits](https://docs.netlify.com/manage/accounts-and-billing/billing/billing-for-credit-based-plans/how-credits-work/) and previews are free. Personal: $9/month for 1,000 credits |
| Database, sign-in, files | [Supabase](https://supabase.com/pricing): Postgres, Auth, Storage | Postgres handles ledgers, totals, and row-level security, and sign-in and files plug into the same rules | Free: 500 MB database, 1 GB files. Pro: $25/month |
| Email | [Resend](https://resend.com/docs/knowledge-base/account-quotas-and-limits) | Sign-in codes, approval requests, receipt reminders | Free: 100/day, 3,000/month. Needs a verified domain |
| Sam's Club lookup | Claude API with [web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool) limited to samsclub.com | Reads current listings the way this blueprint's prices were checked | $10 per 1,000 searches plus tokens. Haiku 5.5 is [$0.10 in / $0.50 out per million tokens](https://platform.claude.com/docs/en/about-claude/pricing), about 1 to 3 cents a lookup, a few cents more if Sonnet 5.5 is needed |
| Code and CI | GitHub private repo + GitHub Actions | Pull requests and tests on every change | Free |
| Tests | Vitest, pgTAP (`supabase test db`), Playwright | Math, database rules, and full flows | Free |

**Why the database isn't on Netlify too.** [Netlify Database](https://docs.netlify.com/build/data-and-storage/netlify-database/billing-and-usage/) bills compute while the database is awake, and it stays awake until 5 minutes after the last request. The Free plan caps it at 48 compute units a month at 10 credits each, which is more than the plan's 300 credits on its own. A register taking sales every school day would hit that. Supabase Free runs the database at no charge as long as it's used once a week, and its sign-in and storage share the database's permission rules, so all three stay together.

**Free-plan catches to plan around**

- Netlify's Free plan is a hard limit. At 0 credits, [every project on the team](https://docs.netlify.com/manage/accounts-and-billing/billing/billing-for-credit-based-plans/billing-faq-for-credit-based-plans/) shows "Site not available" until the next month. Keep the store on its own team, deploy production about once a week, and watch the usage page. Roughly 8 production deploys plus normal traffic should use about half the credits (an estimate).
- Supabase pauses a Free project after 1 week of inactivity, which will happen over winter and summer break. Someone has to restore it from the dashboard before the store opens.
- Supabase Free includes no backups. Pro keeps daily backups for 7 days and never pauses.
- The domain for email is the only other cost, usually about $10 to $20 a year.

**Decision:** build on Free. Before cutover, the Advisor picks Supabase Pro at $25/month or Free plus the weekly encrypted backup from Phase 6, and moves Netlify to Personal at $9/month if credits run tight. Expect a few dollars a month at most in Claude API charges; the cap of 30 lookups a day limits the worst case.

## Architecture

Netlify runs the frontend and the backend functions, and Supabase holds the data. The browser calls Postgres functions for every change, and only Netlify Functions hold keys for outside services.

&#91;embedded content: architecture · devices, app, Supabase, outside services\]

The Postgres box is the one that matters: if a rule lives there, no screen or function can get around it. Supabase Auth also sends its sign-in codes through Resend.

## Frontend

One React app runs on every device: the register, officers' phones and laptops, and the Advisor's browser. It shows screens by role, but the database decides what each person can actually do.

| Screen | Path | Who sees it | What's on it |
| --- | --- | --- | --- |
| Sign in | `/sign-in` | Everyone | Email one-time code |
| Register | `/register` | Register account + cashier PIN | Shift open and close, product grid, cart, payments, voids, refunds, outage entry, training mode |
| Inventory | `/inventory` | Officers | Products, categories, stock adjustments, counts, CSV import |
| Pre-auth | `/preauth`, `/preauth/:id` | Officers, Advisor | Form list, the paper-form layout, Sam's Club lookup, ROI, signatures, purchase, receipt, receiving |
| Gift cards | `/gift-cards` | Officers | Issue, reload, look up, deactivate, print |
| Reports | `/reports` | Officers, Advisor | Dashboard, tabs, PDF and CSV exports |
| Log | `/log` | Officers, Advisor; cashiers see their own shifts | Transaction log and Check Log |
| Members | `/members` | Super Admin | People, roles, PINs, approving sign-ups |
| Settings | `/settings` | Super Admin, Advisor | Store rules, open days, categories |

**Building blocks**

- React Router for screens, TanStack Query for data, and the Supabase JS client for sign-in, RPC calls, and uploads.
- `signature_pad` for signatures, a QR code library for gift cards, and zod to check data coming back from functions.
- `vite-plugin-pwa` so the register installs like an app. Offline sales arrive in Phase 6.

**Frontend rules**

- Every data call goes through a typed wrapper in `src/api/`. Screens never build queries themselves.
- Money is shown through one `formatCents` helper. Components never do math on dollars.
- Hiding a button is a convenience, not security. The database rejects anything a role can't do.
- The register works by keyboard and scanner alone, with large tap targets for touch screens.
- Receipt photos and signature images upload straight from the browser to Supabase Storage, never through a function.

**Folder layout**

```text
src/
  routes/        one folder per screen
  components/    shared UI
  api/           typed wrappers for RPC calls and functions
  lib/           money, dates, and ROI math (unit-tested)
netlify/
  functions/     backend functions
supabase/
  migrations/    database changes, one per change
  tests/         pgTAP tests
e2e/             Playwright tests
docs/SPEC.md     this blueprint
netlify.toml     build and functions settings
```

## Backend

The backend has two halves. Supabase holds the data and enforces every rule, and Netlify Functions do the jobs that need a secret key or an outside service.

**Supabase: data and rules**

- Postgres with the tables in the Data model, row-level security on every table, and one RPC function per action.
- Auth sends one-time codes through Resend's SMTP. Anyone can sign in; a first sign-in becomes a Cashier, and a deactivated member's email is turned away.
- Storage buckets: `receipts` and `signatures` are private and shown through short-lived signed URLs. `product-images` can be read publicly.

| RPC group | Functions | Called by |
| --- | --- | --- |
| Shifts and sales | `open_shift`, `complete_sale`, `void_sale`, `refund_sale`, `record_handoff`, `close_shift`, `log_outage_sale`, `verify_outage_sale` | Register |
| Inventory | `save_product`, `change_price`, `archive_product`, `adjust_stock`, `start_count`, `approve_count` | Officers |
| Pre-auth | `save_preauth`, `sign_preauth`, `reject_preauth`, `record_purchase`, `add_receipt`, `receive_preauth`, `approve_overage`, `close_preauth` | Officers, Advisor |
| Gift cards | `issue_gift_card`, `reload_gift_card`, `deactivate_and_transfer` (redeeming happens inside `complete_sale`) | Register, officers |
| Admin and log | `save_member`, `set_pin` (Super Admin; members change their own PIN once set), `save_settings` and `verify_log` (Super Admin, Advisor), `ensure_member` (anyone signed in with an email code) | as listed |

**Netlify Functions: secret keys and outside services**

| Function | Kind | Runs when | What it does |
| --- | --- | --- | --- |
| `sams-lookup` | Standard, up to 60 seconds | An officer searches Sam's Club | Calls the Claude API with web search on samsclub.com, checks the JSON, saves the listing |
| `preauth-pdf` | Standard | The Advisor approves, and again at close | Draws the paper-form PDF with pdf-lib and stores it |
| `notify` | Standard | A pre-auth is submitted, approved, or rejected | Re-checks the form's status, then emails the next person through Resend |
| `daily-reminders` | [Scheduled](https://docs.netlify.com/build/functions/scheduled-functions), `0 12 * * *` in UTC | 8 AM Eastern during daylight saving time, 7 AM in winter | Flags overdue receipts and emails the Advisor |

**How a function checks who's calling**

1. The browser sends the member's Supabase access token with each request.
2. The function verifies the token with Supabase and loads the member's role.
3. It calls Supabase with that same token, so row-level security still applies.
4. Only `daily-reminders` uses the service role key, because nobody is signed in when it runs.

**Environment variables**

| Variable | Set in | Used by |
| --- | --- | --- |
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | Netlify build settings and `.env.local` | Frontend. These are public by design |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Netlify, scoped to Functions | `daily-reminders` |
| `ANTHROPIC_API_KEY` | Netlify, scoped to Functions | `sams-lookup` |
| `RESEND_API_KEY` | Netlify, scoped to Functions, and Supabase Auth's SMTP settings | `notify`, `daily-reminders`, sign-in codes |

Only variables starting with `VITE_` reach the browser bundle, so the secret ones never get a `VITE_` prefix.

## Data model

Twenty-two Postgres tables, plus a `legacy_sales` table that holds the imported Base44 history. Money is stored as whole cents in `bigint` columns, and every table has row-level security turned on.

| Table | Holds | Key columns |
| --- | --- | --- |
| `members` | People who can sign in | user\_id, email, display\_name, grade, role, is\_super\_admin, pin\_hash, active |
| `settings` | Store rules | float\_cents, over\_short\_tolerance\_cents, preauth\_limit\_cents (30000), receipt\_due\_days (5), school\_year\_start, open\_days |
| `categories` | Managed category list | name, sort\_order, active |
| `products` | Items for sale | sku, upc, name, category\_id, price\_cents, avg\_cost\_cents, cost\_status, low\_stock\_alert, image\_path, smart\_snack, status |
| `price_changes` | Price history | product\_id, old\_cents, new\_cents, by, at |
| `stock_movements` | Every stock change | product\_id, qty, type, unit\_cost\_cents, source\_type, source\_id, reason, by, at |
| `stock_counts` + `stock_count_lines` | Count sessions | started\_by, approved\_by, product\_id, expected, counted |
| `shifts` | One drawer session | cashier\_id, opened\_at, opening\_cash\_cents, closed\_at, counted\_cash\_cents, expected\_cash\_cents, over\_short\_cents, note |
| `cash_handoffs` | Cash leaving the drawer | shift\_id, amount\_cents, from\_id, to\_id, both signatures |
| `sales` | One checkout | number, client\_uuid, shift\_id, cashier\_id, type, status, total\_cents, note |
| `sale_lines` | Items in a sale | sale\_id, product\_id, qty, unit\_price\_cents, unit\_cost\_cents, refunded\_qty |
| `payments` | How a sale was paid | sale\_id, method, amount\_cents, gift\_card\_id |
| `refunds` | Money back | sale\_id, amount\_cents, method, return\_to\_shelf, reason, approved\_by |
| `vendor_items` | Saved Sam's Club listings | item\_number, url, name, units\_per\_pack, price\_cents, sale\_price\_cents, checked\_at, product\_id |
| `preauths` | The purchase order form | number, status, requester\_id, grade, fbla\_role, request\_date, vendor, website, purposes, justification, shipping\_cents, grand\_total\_cents, approved\_total\_cents, purchase\_date, receipt\_due\_date, notes |
| `preauth_lines` | Requested and received items | preauth\_id, vendor\_item\_id, product\_id or new\_name, units\_per\_pack, packs, est\_pack\_price\_cents, sell\_price\_cents, packs\_bought, actual\_pack\_price\_cents, units\_received |
| `signatures` | Drawn signatures | document\_type, document\_id, role, member\_id, typed\_name, strokes, image\_path, signed\_at, doc\_hash, voided\_at |
| `receipts` | Purchase proof | preauth\_id, file\_path, total\_cents, tax\_cents, uploaded\_by |
| `gift_cards` | One card | code, type (paid or promo), status, issued\_by, note |
| `gift_card_txns` | Card ledger | card\_id, type, amount\_cents, sale\_id, by, at |
| `log_entries` | Transaction log | seq, at, actor\_id, role, device, action, record\_type, record\_id, amount\_cents, before, after, reason, prev\_hash, hash |

**Database rules**

- The browser never writes tables directly. Every change is a Postgres function called over RPC. It checks the caller's role, runs in one transaction, and writes its `log_entries` row in that same transaction.
- `log_entries` rejects UPDATE and DELETE for every role through revoked grants and a trigger that raises an error. A trigger fills `seq` and the hash chain: hash = SHA-256 of the previous hash plus the new entry.
- Stock on hand is a view that sums `stock_movements`. Gift card balance is a view that sums `gift_card_txns`. Neither has an editable column.
- `complete_sale` is idempotent on `client_uuid`, so a sale sent twice by a flaky connection is saved once.
- Gift card redemption locks the card row, so two registers can't spend the same balance at once.
- Migrations live in `supabase/migrations` and are never edited after they merge.

## Roles and permissions

Each member has one role: Advisor, President, Treasurer, or Cashier. Super Admin is a separate flag for running the system, and it never lets anyone sign in someone else's place.

| Action | Super Admin | Advisor | President | Treasurer | Cashier |
| --- | --- | --- | --- | --- | --- |
| Ring sales, open and close own shift | ✓ | ✓ | ✓ | ✓ | ✓ |
| Sell, reload, and redeem gift cards | ✓ | ✓ | ✓ | ✓ | ✓ |
| Void or refund a sale | ✓ | ✓ | ✓ | ✓ | With officer PIN |
| Issue promo gift cards | ✓ | ✓ | ✓ | ✓ | — |
| Edit products, prices, categories | ✓ | ✓ | ✓ | ✓ | — |
| Stock counts and adjustments | ✓ | ✓ | ✓ | ✓ | — |
| Request a purchase and sign as Student | — | — | ✓ | ✓ | — |
| Approve and sign a pre-auth | — | ✓ | — | — | — |
| Record the purchase and upload the receipt | — | ✓ | ✓ | ✓ | — |
| Approve an overage, close a pre-auth | — | ✓ | — | — | — |
| Record receiving | ✓ | ✓ | ✓ | ✓ | — |
| Verify an outage entry (not your own) | ✓ | ✓ | ✓ | ✓ | — |
| View reports | ✓ | ✓ | ✓ | ✓ | — |
| View the transaction log | ✓ | ✓ | ✓ | ✓ | Own shifts |
| Add members, set roles, reset PINs | Super Admin only | — | — | — | — |
| Change settings | ✓ | ✓ | — | — | — |
| Edit or delete log entries | — | — | — | — | — |

A Super Admin's own role still decides what they can sign. You would be President with the Super Admin flag. Roles are reassigned each fall by the Advisor, and every change is logged.

## Feature specs

These are the behaviors Claude Code builds against, module by module. The pre-auth has its own section next.

**Register and cash**

- The register device stays signed in as a shared Register account. A cashier starts a shift with a 4-digit PIN and counts the opening cash. No sale can be rung without an open shift.
- Tap or scan to add items. Sold-out items are grayed out and can't be added.
- Payments are Cash, Gift Card, or Promo Card, and one sale can split across them.
- Sale types: Regular, Staff, Comp (reason required), Outage, Training. An optional note, never a buyer name.
- Closing counts the drawer by bill and coin. Expected cash = opening cash + cash sales + cash gift card loads − cash refunds − cash handoffs. Over/short beyond $1.00 needs a note and an officer PIN.
- A void cancels a whole sale in the same shift. A refund comes later, whole or by item. Both need a reason, and cashiers need an officer PIN. "Return to shelf" puts items back in stock. Card-paid refunds go back onto the card.
- Outage backup: print the Outage Tally Sheet, sell on paper, then enter the totals with a photo of the sheet. The entry stays Pending until a different officer verifies it.
- Training mode is labeled on screen and never touches stock, cash, or reports.
- A USB barcode scanner types the code and presses Enter. The register catches that and adds the product with the matching UPC.

**Inventory**

- Movement types: Sale, Refund to shelf, Receiving, Opening balance, Count adjustment, Damaged, Expired, Missing, Found, Import adjustment.
- Unit cost = pack price ÷ units per pack, with receipt tax spread across lines by dollar share. Receiving updates the product's cost as a weighted average:

```latex
\text{new cost} = \frac{\text{on hand} \times \text{old cost} + \text{received} \times \text{receipt cost}}{\text{on hand} + \text{received}}
```

- Products with no cost show "Cost missing" and are left out of margin.
- Counts: a weekly quick count of the 10 fastest sellers and a full count monthly and at year end. Approving a count posts the adjustments.
- Every product gets an auto SKU (FBLA-0001), an optional scanned UPC, price history, a Smart Snacks flag, and an image stored in the app. Archive replaces delete.

**Gift cards**

- Codes are 10 random characters without 0, O, 1, or I, printed with a QR code. Cards aren't tied to a name and don't expire.
- Paid cards: selling or reloading adds to what the store owes, and spending counts as revenue at that moment. Promo cards: spending records cost of goods with $0 revenue, reported as promo cost.
- Lost card: deactivate it and move the balance to a new card. Balance checks happen on the register screen only.
- Balances carry into the next year, and the year-end report lists every card that still has money on it.

**Transaction log**

- Logs sales, voids, refunds, outage entries, shifts, handoffs, every stock movement, counts, price and product changes, imports, every pre-auth step, every gift card action, sign-ins, role changes, and settings changes.
- Each entry holds its sequence number, time, person, role, device, action, linked record, amount, before and after values, reason, and hash.
- A Check Log button runs `verify_log()` and reports any break in the numbering or the hash chain.
- Filter by date, person, action, item, or amount. Every entry links to its record. Export CSV or PDF.

**Reports**

- Count completed sales minus refunds. Leave out Training and Pending sales and gift card loads.
- Default to the school year (September 1 to June 30) and compare with the same period last year, including the imported Base44 history.
- Dashboard: revenue, cost of goods, profit, margin, sales count, average sale, open days, and revenue per open day.
- Tabs: Products, Restock, Cash, Gift Cards, Shrink, Purchasing, Staff and Comps.
- Forecast = revenue per open day × open days planned in Settings. With fewer than 10 open days of history it says "Not enough recent sales" instead of a number.
- PDFs: shift closeout, Monthly Treasurer Report, and year-end report. Every table exports to CSV.

## Pre-auth purchasing

No Sam's Club purchase happens without the Preauthorization Purchase Order Form signed by the requesting student and the Advisor, and nothing reaches the shelf until it is received against that form.

&#91;embedded content: pre-auth flow · 6 steps, reject loop\]

A rejection, or any edit after the student signs, clears the signatures and sends the form back to Draft. Stock changes only at Received.

**The digital form mirrors the paper form**

| Paper form section | Digital field | How it fills |
| --- | --- | --- |
| Student Information | Name, grade, FBLA role | From the signed-in member |
| Date of Request | Request date | Today |
| Item(s) to be Purchased | Line items | Sam's Club lookup |
| Vendor/Store, Website | Vendor, product links | Sam's Club by default; each line keeps its link |
| Purpose | Competition, Event, Fundraiser, Supplies, Other | Checked by the student; Other needs a description |
| Justification | Justification | Typed by the student, with the ROI summary under it |
| Cost Information | Estimated cost, qty, total, shipping, grand total | Calculated from the lines |
| Approvals | Student and Advisor signatures with dates | Signature pad, dated automatically |
| Notes | Notes | Optional |

**Rules from the form, enforced by the app**

- **Maximum $300.** Grand total = line totals + shipping. Submitting is blocked above $300, and the total turns amber within $20 of it, since tax at checkout can push it over.
- **Preapproval required.** Nothing can be marked Purchased until the Advisor signs.
- **Receipts due in 5 days.** The countdown starts on the purchase date. A daily scheduled job flags the form Overdue on day 6 and emails the Advisor.
- **No unauthorized reimbursement.** Reimbursement can't be recorded until a receipt is uploaded. A receipt over the approved total needs the Advisor's sign-off.
- **Keep copy.** Every signed form renders as a PDF laid out like the paper form, with Attachment A listing the items and payoff. It's stored and emailed to both signers.

**Sam's Club lookup**

- A Netlify Function, `sams-lookup`, takes a samsclub.com link or an item name. It calls the Claude API with the web search tool set to `allowed_domains: ["samsclub.com"]` and `max_uses: 3`, and asks for JSON: name, item number, units per pack, regular price, sale price, URL.
- The function validates the JSON with zod and rejects any URL outside samsclub.com, then saves the listing to `vendor_items` with `checked_at`. A listing checked in the last 7 days is reused without a new search.
- Model: Haiku 5.5 if the Models API reports web search support for it (`capabilities.server_tools.web_search.supported`), otherwise Sonnet 5.5. Limit lookups to 30 a day.
- Fallbacks: paste the text of the product page for Claude to read without searching, or type the item in.
- Online and in-club prices can differ, so receiving records the real price from the receipt.
- Only product text goes to the API, never student data.

**ROI on every line**

- Units = packs × units per pack. Cost = packs × pack price. Revenue = units × the store's selling price. Profit = revenue − cost.
- ROI = profit ÷ cost. Margin = profit ÷ revenue. Break-even = cost ÷ revenue, shown as "money back after selling X% of it."
- Weekly sales = last school year's units ÷ weeks with at least one sale. Weeks of supply = (on hand + new units) ÷ weekly sales, with a warning above 10 weeks.
- Suggest packs = (weekly sales × 6 weeks − on hand) ÷ units per pack, rounded up.
- The form shows request totals for cost, revenue, profit, and ROI so the Advisor sees the payoff before signing.

**Signatures**

- Drawn with the `signature_pad` library plus a typed name. The date is added automatically.
- Saved: the strokes, a PNG in private storage, the signer, role, time, and a SHA-256 hash of the form's fields and lines, computed in Postgres.
- Only the member who holds a role can sign as that role. Any edit after signing marks the signatures voided and returns the form to Draft.

**Receiving and closing**

- For each line: packs bought, actual pack price, units received, and an optional substitute product. A receipt photo is required.
- Posting creates Receiving stock movements and updates weighted average costs. Closing locks the form with its PDF attached.
- Before cutover, receiving records real costs in the new app. The opening count at cutover sets the stock.

## Security and privacy

The database enforces every permission, so a bug in the app can't skip a rule, and the app keeps as little student data as the forms allow.

**Sign-in**

- Members sign in with a one-time code emailed to their school address through Supabase Auth, sent by Resend. This works without district IT changing anything.
- Sign-up is open: anyone's first sign-in with an email code makes them a Cashier (`ensure_member()`). A Cashier can't open a shift until a Super Admin sets their first PIN, and the register's people picker shows a plain Cashier only themselves and the officers. Deactivating a member blocks them, and their email can't make a new account.
- Google sign-in can come later. Google blocks student accounts designated under 18 from [unconfigured third-party apps](https://knowledge.workspace.google.com/admin/getting-started/editions/manage-access-to-unconfigured-third-party-apps-for-users-designated-as-under-18) until district IT configures the app in the Admin console.
- The register stays signed in as a shared Register account. Cashiers identify themselves with PINs hashed by pgcrypto `crypt()`, and 5 wrong tries lock that cashier out for 5 minutes, and each lockout after that doubles (up to a day) until the right PIN or a reset.

**Enforced in the database**

- Row-level security is on for every table and denies by default.
- RPC functions run as `security definer` with a fixed `search_path`, and each one checks the caller's role before doing anything.
- The service role key lives only in Netlify environment variables scoped to Functions, and only the scheduled job uses it. It never reaches the browser or the repo.
- Receipts and signatures sit in private storage buckets and display through short-lived signed URLs.

**Student data (NY Education Law 2-d)**

- Store only what the forms need: officer names, school emails, grade, and signatures. No buyer names and no student ID numbers.
- When a district shares student personal information with an outside service, Ed Law 2-d and Part 121 call for a contract that includes the vendor's data privacy and security plan, plus a posted Parents' Bill of Rights supplement. NYSED offers a [model data privacy agreement](https://www.nysed.gov/sites/default/files/data-privacy-security/memo/nysed-enforcement-state-student-privacy-law.pdf) for this.
- Before real student data goes in, ask the district's IT office or data protection officer how they want Supabase, Netlify, Resend, and the Claude API handled. Build and test with made-up names until then.
- The Sam's Club lookup sends product text only.

**Secrets**

- Local keys go in `.env.local`, function keys in Netlify environment variables, and `.env*` files in `.gitignore`.
- The Anthropic API key belongs to the chapter's Console account and has a monthly spend limit.
- Replace any key or password that ends up in a chat, an issue, or a commit.

## CLAUDE.md

Paste this into `CLAUDE.md` at the repo root. Claude Code loads it at the start of every session, and the [docs](https://code.claude.com/docs/en/memory) recommend keeping it under 200 lines, so the full spec stays in `docs/SPEC.md` and gets read only when a task needs it.

```markdown
# CPPHS FBLA Store App

Point of sale and back office for the Corning-Painted Post High School FBLA school store: register and cash shifts, inventory, Sam's Club pre-auth purchasing with signatures, gift cards, an append-only transaction log, and Treasurer reports.

Full spec: `docs/SPEC.md`. Read the section for your task before planning.

## Stack
- Frontend: React + TypeScript + Vite, Tailwind, React Router, TanStack Query. Installable PWA.
- Backend: Supabase (Postgres with row-level security, Auth with email one-time codes, Storage) plus Netlify Functions in `netlify/functions` (Node, TypeScript).
- Netlify hosts the frontend and the functions. Pull requests get deploy previews; merging to `main` deploys production.
- Email: Resend. Sam's Club lookup: Claude API, called only from the `sams-lookup` function.

## Commands
- `netlify dev`: app and functions together at http://localhost:8888
- `npx supabase start`, then `npx supabase db reset`: local database with all migrations and `supabase/seed.sql`
- `npm run typecheck` and `npm run lint`
- `npm test`: Vitest unit tests
- `npm run test:db`: pgTAP database tests (`supabase test db`)
- `npm run e2e`: Playwright end-to-end tests

## Rules that must never break
- IMPORTANT: Money is integer cents (`bigint` in Postgres, a number of cents in TypeScript). Never floats. Format only for display.
- Every write that touches money, stock, approvals, or access is a Postgres function called over RPC. It checks the caller's role, runs in one transaction, and writes its `log_entries` row in that same transaction. The browser never inserts or updates tables directly.
- `log_entries` is append-only. Never write UPDATE or DELETE against it, and never change old rows in a migration. Fix mistakes with a new reversing entry.
- Stock on hand is the sum of `stock_movements`. Gift card balance is the sum of `gift_card_txns`. Never add an editable stock or balance column.
- `sale_lines.unit_cost_cents` is saved at the moment of sale. Reports use it, never the product's current cost.
- Nothing is deleted. Archive products; void or refund sales.
- Every new table gets RLS enabled and explicit policies in the same migration.
- Netlify Functions verify the caller's Supabase token and call Supabase with it. Only scheduled functions use the service role key.
- Never store a buyer's name. Never send student data to the Claude API.
- Pre-auth limits come from `settings`: $300 per form, receipt due 5 days after purchase.

## Workflow
- One migration per change in `supabase/migrations`. Never edit a migration after it merges.
- Money logic ships with tests: Vitest for math, pgTAP for RPCs and RLS.
- When you finish a change, run typecheck, lint, `npm test`, and `npm run test:db`, and show the output.
- Work on a branch per phase and open a PR into `main`.
- Ask before adding a dependency.

## Gotchas
- Time zone is America/New_York. Store `timestamptz`; school-day logic uses local dates. Netlify scheduled functions run on UTC cron.
- Uploads go straight from the browser to Supabase Storage. Function request bodies are capped at 6 MB.
- Each production deploy uses 15 of Netlify's 300 free monthly credits. Test on deploy previews and deploy production about once a week.
- The school year runs September 1 to June 30.
- Supabase Free pauses a project after a week without activity. If the hosted project stops answering, check that first.
```

## Build phases

Seven phases, each a pull request you can use when it merges. Pre-auth goes live after Phase 2, while Base44 keeps running the register until the cutover gate.

&#91;embedded content: build roadmap · 7 phases, 1 gate\]

The gate is the only hard stop. Base44 stops ringing sales only after the new register has matched the drawer at every shift close for a full week.

## Claude Code prompts

Paste one prompt per phase into a fresh Claude Code session in plan mode. Each one names the spec sections to read, the scope, and the tests that prove it's done.

**Phase 0: Setup**

```text
Set up the CPPHS FBLA store app from an empty repo. Read CLAUDE.md and the "Tech stack", "Frontend", "Backend", and "Security and privacy" sections of docs/SPEC.md first. Make a plan and wait for my OK.

1. Scaffold the frontend: React + TypeScript with Vite, Tailwind, React Router, TanStack Query, and the Supabase JS client, using the folder layout in the Frontend section. Make it an installable PWA.
2. Set up Netlify: netlify.toml for the Vite build, a netlify/functions folder with a TypeScript health function, and `netlify dev` running the app and functions together.
3. Initialize the Supabase CLI project: supabase/config.toml, a first migration, supabase/seed.sql, and a supabase/tests folder for pgTAP.
4. Add npm scripts: build, typecheck, lint, test (Vitest), test:db (supabase test db), and e2e (Playwright).
5. Add .env.example listing every variable in the Backend section's table. Make sure .env* files are gitignored.
6. Add a GitHub Actions workflow that runs typecheck, lint, test, and test:db on every pull request.
7. Make a placeholder home page titled "CPPHS FBLA Store" that shows whether it reached Supabase and the health function.

Done when `netlify dev` shows the page with both checks passing and typecheck, lint, test, and test:db all pass. Show me the output, then commit on a branch named phase-0 and open a pull request. I'll connect the repo to Netlify so the pull request gets a deploy preview.
```

**Phase 1: Foundation**

```text
Build Phase 1, Foundation. Read docs/SPEC.md sections "Data model", "Roles and permissions", "Security and privacy", and the Inventory and Transaction log parts of "Feature specs". Make a plan and wait for my OK.

1. Migrations for members, settings, categories, products, price_changes, stock_movements, a product_stock view, and log_entries. Money in bigint cents. RLS on every table.
2. Sign-in with Supabase Auth email one-time codes. Anyone can sign in and starts as a Cashier; deactivated members are blocked. Seed depedros@cppasd.com as President and Super Admin, and depedroshawn@gmail.com as Super Admin with no role.
3. Roles: advisor, president, treasurer, cashier, plus an is_super_admin flag. One SQL function answers "can the current user do this action" and every RLS policy and RPC uses it. A Members page for Super Admins to approve people, set roles, make other Super Admins, and set or reset PINs (hashed with pgcrypto crypt(); 5 wrong tries lock that cashier out for 5 minutes, doubling with each later lockout up to a day).
4. Transaction log: log_entries is append-only. A trigger assigns seq and sets hash = SHA-256 of prev_hash plus the canonical JSON of the new entry. Revoke UPDATE and DELETE from every role and add a trigger that raises an error on either. Add verify_log() to recheck the numbering and the chain. A Log page with filters, links to records, and CSV export.
5. Products: managed categories, auto SKU (FBLA-0001), optional UPC, price history, Smart Snacks flag, archive instead of delete, images uploaded to Storage, and a "Cost missing" badge.
6. Stock: on hand = sum of stock_movements. An Adjust Stock action with reasons Damaged, Expired, Missing, Found, and Count correction. Each change is one RPC that writes the movement and its log entry in a single transaction.
7. Import: a script that reads Base44's product CSV export (name, sku, category, price, cost, stock, image_url, description) into products with Opening balance movements, and its sales CSV export into a legacy_sales table. Copy the old customer field into a note column, never a name column.

Tests (pgTAP): a cashier can't read members or log_entries; UPDATE and DELETE on log_entries fail for every role; verify_log() catches a row a superuser changed; stock equals the sum of movements after a mix of changes; a non-member can't call any RPC. Vitest: cents parsing and formatting.

Done when every test passes. Show the output, then open a pull request for phase-1.
```

**Phase 2: Pre-auth**

```text
Build Phase 2, Pre-auth. Read the "Pre-auth purchasing" section of docs/SPEC.md. I'm attaching a photo of our paper Preauthorization Purchase Order Form and screenshots of the demo; match their layout. Make a plan and wait for my OK.

1. Migrations for vendor_items, preauths, preauth_lines, signatures, and receipts, with RLS. Statuses: draft, awaiting_advisor, approved, purchased, received, closed, rejected.
2. The form: Student Information from the signed-in member, request date, vendor (default Sam's Club), website, purpose checkboxes with Other text, justification, lines, shipping, grand total, and notes.
3. Netlify Function sams-lookup (it has 60 seconds to finish): takes a samsclub.com link or an item name, calls the Claude API with the web search tool (allowed_domains ["samsclub.com"], max_uses 3), and asks for JSON with name, item_number, units_per_pack, price, sale_price, and url. Validate with zod, reject URLs outside samsclub.com, save to vendor_items with checked_at, and reuse anything checked in the last 7 days. Use claude-haiku-5-5 if the Models API reports web search support for it, otherwise claude-sonnet-5-5. Limit it to 30 lookups a day. Add a paste-the-page-text fallback that doesn't search, and manual entry. Send no student data.
4. ROI per line and in total with the spec's formulas, a Suggest packs button, and a warning above 10 weeks of supply. Sales history comes from legacy_sales until the new register has a year of data.
5. Grand total = lines + shipping. Block submitting above $300 (from settings) and warn within $20.
6. Signatures with signature_pad: drawn signature plus typed name, dated automatically. Store the strokes, a PNG in a private bucket, signer, role, time, and a SHA-256 hash of the form computed in Postgres. The student signs first; only a member with the advisor role can approve. Call the notify function to email the Advisor through Resend when a form is waiting. Any edit after signing voids the signatures and returns the form to draft. Rejecting needs a comment.
7. After approval, recording the purchase date sets receipt_due_date to 5 days later. A daily Netlify scheduled function, daily-reminders, marks overdue forms and emails the Advisor. Reimbursement can't be recorded without a receipt, and a receipt over the approved total needs the Advisor's sign-off.
8. Receiving: per line, packs bought, actual pack price, units received, and an optional substitute, with a required receipt photo. One RPC posts Receiving stock movements and updates weighted average cost.
9. A PDF of the signed form laid out like the paper form, plus Attachment A with the items and payoff, made with pdf-lib in the preauth-pdf Netlify Function. Store it and email it to both signers.

Tests: the $300 block; the hash changing when any line changes; an edit voiding signatures; a cashier unable to approve; the receipt due date and overdue flag; weighted average cost after receiving; and a Playwright run from draft to closed. Show the output, then open a pull request for phase-2.
```

**Phase 3: Register and cash**

```text
Build Phase 3, Register and cash. Read the "Register and cash" part of "Feature specs" in docs/SPEC.md. Make a plan and wait for my OK.

1. Migrations for shifts, cash_handoffs, sales, sale_lines, payments, and refunds, with RLS.
2. A shared Register account. Cashiers open a shift with their PIN and an opening cash count (default from settings). No sale without an open shift.
3. complete_sale RPC: one transaction that saves the sale, its lines with unit_cost_cents from the product's current average cost, payments, Sale stock movements, and the log entry. Idempotent on client_uuid. Rejects items with no stock.
4. Register screen: product grid with images and search, sold-out items disabled, cart, cash with change due, split payment ready for gift cards, sale type, and note. USB scanner support: a fast burst of keys ending in Enter adds the product with that UPC.
5. Close shift: count by bill and coin, expected cash from the spec formula, over/short, a note plus an officer PIN above $1.00, and a closeout PDF.
6. Voids (same shift) and refunds (by item, any time) with reasons, an officer PIN for cashiers, and Return to shelf creating a Refund to shelf movement.
7. Cash handoffs signed by both people.
8. Outage: a printable Outage Tally Sheet, then an entry form with a required photo of the sheet. Pending until a different officer verifies it.
9. Training mode: labeled on screen, and nothing it does touches stock, cash, or reports.

Tests: change due and over/short math; complete_sale saving once when sent twice; a void restoring stock; a partial refund; training sales leaving no movements; a cashier unable to refund without an officer PIN; and a Playwright shift that opens, sells, voids, refunds, and closes at $0.00 over/short. Show the output, then open a pull request for phase-3.
```

**Phase 4: Gift cards**

```text
Build Phase 4, Gift cards. Read the "Gift cards" part of "Feature specs" in docs/SPEC.md. Make a plan and wait for my OK.

1. Migrations for gift_cards and gift_card_txns with RLS, and a gift_card_balance view. No balance column.
2. Codes: 10 random characters without 0, O, 1, or I, from a cryptographic random source. Printable cards with a QR code.
3. Register: a Gift card load line to sell or reload (cash in, not product revenue), Gift Card as a payment method with split payment, and refunds of card-paid sales back onto the card.
4. Redemption locks the card row so a balance can never go below $0, even with two registers at once.
5. Promo cards: only the Treasurer and up can issue them. Spending one records cost of goods with $0 revenue.
6. Lost card: deactivate it and move the balance to a new card.
7. Import any Base44 gift cards that still have a balance, as Issue transactions dated today.
8. Gift card report: outstanding paid and promo balances, issued, redeemed, and promo cost for a date range.

Tests: balance equals the sum of transactions; overdrawing fails; two concurrent redemptions can't overdraw; refunds return to the card; promo spending shows $0 revenue. Show the output, then open a pull request for phase-4.
```

**Phase 5: Reports**

```text
Build Phase 5, Reports. Read the "Reports" part of "Feature specs" in docs/SPEC.md. Make a plan and wait for my OK.

1. SQL views or RPCs for every number, so the math lives in the database and is tested once: completed sales minus refunds, no Training or Pending sales, no gift card loads, profit from unit_cost_cents, and margin on known-cost items only.
2. A dashboard with a date range that defaults to the school year and compares with the same period last year, including legacy_sales.
3. Tabs: Products, Restock (with a Start pre-auth button), Cash, Gift Cards, Shrink, Purchasing, and Staff and Comps.
4. Forecast = revenue per open day x open days planned in settings, showing "Not enough recent sales" below 10 open days.
5. The Monthly Treasurer Report and year-end report as PDFs, and CSV export on every table.

Tests: a fixture week of sales, refunds, comps, and gift card activity whose report totals match numbers worked out by hand in the test. Show the output, then open a pull request for phase-5.
```

**Phase 6: Hardening**

```text
Build Phase 6, Hardening. Read docs/SPEC.md sections "Security and privacy" and "Testing, cutover from Base44, and handoff". Make a plan and wait for my OK.

1. Offline sales: when the register loses its connection, queue sales in IndexedDB with their client_uuid, show "Offline, 3 sales waiting", and send them on reconnect. complete_sale is already idempotent.
2. Backups, if we stay on Supabase Free: a weekly GitHub Action that dumps the database, encrypts it with a passphrase the Advisor holds, and keeps 8 weeks. Write the restore steps.
3. Use a subagent to review the whole repo against the spec for RLS gaps, RPCs missing role checks, secrets in code, and public storage buckets. Fix what it finds and add a test for each fix.
4. Accessibility pass on the register and pre-auth screens: keyboard use, focus states, labels, and contrast.
5. Write README.md (setup) and RUNBOOK.md (opening the store, closing a shift, restoring after a Supabase pause, adding members each fall, handing off accounts).

Done when the offline test passes in Playwright with the network cut, a backup runs and restores into a local database, and the review findings are fixed. Show the output, then open a pull request for phase-6.
```

## Testing, cutover, and handoff

Base44 stays the register until the new one survives a full week of real shifts. Then Base44 goes read-only and the Advisor takes ownership of every account.

| Test layer | Tool | What it proves |
| --- | --- | --- |
| Unit | Vitest | Cents math, ROI, expected cash, gift card codes |
| Database | pgTAP through `supabase test db` | Permissions by role, the append-only log, RPC rules, balances |
| End to end | Playwright | A full shift, a pre-auth from draft to closed, offline sales |
| Review | A Claude Code subagent | Each phase's diff checked against `docs/SPEC.md` |

CI runs unit and database tests on every pull request.

**Cutover checklist (after Phase 4)**

- [ ] Export every Base44 table to CSV and save the files to the chapter's district Google Drive.
- [ ] Import products and sales history (Phase 1 script) and gift card balances (Phase 4).
- [ ] Count all stock the day before and post it as Opening balance.
- [ ] Set cashier PINs and have each cashier ring a few practice sales in Training mode.
- [ ] Run the new register for one week. The drawer count has to match the app at every shift close.
- [ ] Settle Supabase Pro versus Free with the weekly backup.
- [ ] Confirm the district's answer on student data is on file.
- [ ] Stop using the Base44 register and keep its export.

**Handoff before you graduate**

- The Advisor owns the GitHub organization, Supabase organization, Netlify team, Resend account, domain, and Anthropic Console account. You stay on as a member.
- The Advisor holds the Super Admin flag, and each fall's officers get their roles from the Advisor.
- `README.md` and `RUNBOOK.md` from Phase 6 cover setup, daily use, restoring after a pause, and handing off accounts.
- Have a younger student shadow at least one phase so someone can keep fixing it after you leave.

## Open items

The first two block real use: settle them before officers put real names into the app.

- [ ] District IT or the data protection officer: is it OK to keep officer names, school emails, grades, and signatures in Supabase, Netlify, and Resend?
- [ ] Which domain the chapter will own for email, and who pays for it.
- [ ] Who owns the accounts and pays: Supabase Pro at $25/month or Free with weekly backups, plus the Claude API at a few dollars a month at most.
- [ ] Starting cash float for each shift.
- [ ] How Sam's Club purchases get paid, and whose membership is used.
- [ ] Whether any Base44 gift cards still have balances.
- [ ] Which device runs the register, and how reliable the store's Wi-Fi is.
- [ ] The 2026–27 store open days, for the forecast.
- [ ] Whether district IT will configure Google sign-in later.

## Sources

Prices and limits were checked on October 14, 2026.

- [Supabase pricing](https://supabase.com/pricing): Free and Pro limits, pausing, backups
- [Supabase custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp): built-in email limits
- [Netlify pricing](https://www.netlify.com/pricing/) and [how credits work](https://docs.netlify.com/manage/accounts-and-billing/billing/billing-for-credit-based-plans/how-credits-work/): plan credits, deploy and compute costs
- [Netlify billing FAQ for credit-based plans](https://docs.netlify.com/manage/accounts-and-billing/billing/billing-for-credit-based-plans/billing-faq-for-credit-based-plans/): what happens at 0 credits
- [Netlify Functions configuration](https://docs.netlify.com/build/functions/configuration) and [scheduled functions](https://docs.netlify.com/build/functions/scheduled-functions): time limits, payload limits, UTC schedules
- [Netlify Database usage meters](https://docs.netlify.com/build/data-and-storage/netlify-database/billing-and-usage/): Free plan database limits
- [Resend quotas and limits](https://resend.com/docs/knowledge-base/account-quotas-and-limits): free email quota
- [Google Workspace: unconfigured third-party apps for users under 18](https://knowledge.workspace.google.com/admin/getting-started/editions/manage-access-to-unconfigured-third-party-apps-for-users-designated-as-under-18)
- [NYSED memo on Education Law § 2-d and Part 121](https://www.nysed.gov/sites/default/files/data-privacy-security/memo/nysed-enforcement-state-student-privacy-law.pdf)
- [Claude API web search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool) and [Claude API pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- [Claude Code: CLAUDE.md and memory](https://code.claude.com/docs/en/memory), [best practices](https://code.claude.com/docs/en/best-practices), and [common workflows](https://code.claude.com/docs/en/common-workflows)
