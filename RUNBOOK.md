# CPPHS FBLA Store runbook

Plain steps for running the store app. The app is at the frontend site's address; everything below assumes you are signed in with your school email.

## Opening the store

1. On the store laptop, open the app. It stays signed in as the shared **Register** account.
2. Go to **Register**. Pick your name, enter your 4-digit PIN, and count the opening cash by bill and coin. The default float comes from Settings.
3. Ring sales. A USB scanner works anywhere on the register screen: scan, and the item drops into the cart.

If Wi-Fi is down: print the **Outage Tally Sheet** from the register's Outage tab, sell on paper, and later enter the totals with a photo of the sheet. A different officer verifies the entry before it counts.

## Closing a shift

1. Register > **Close shift**. Count the drawer by bill and coin.
2. The app shows expected cash (opening + cash sales + cash gift card loads − cash refunds − handoffs) and the over/short.
3. Off by more than $1.00? Add a note and have an officer enter their PIN.
4. Print or save the closeout PDF and put it with the cash.

Handing cash to the Treasurer mid-shift: Register > **Handoff**. Both people enter their PINs and sign.

## Pre-auth purchases (Sam's Club)

1. A student officer starts a form under **Pre-auth**, looks items up (paste a samsclub.com link or type a name), checks the ROI, and signs. The app blocks anything over $300.
2. The Advisor gets an email, reviews the payoff, and signs or rejects with a comment. Any edit after signing clears the signatures.
3. After buying, record the purchase date. The receipt is due in 5 days; on day 6 the form is flagged Overdue and the Advisor is emailed.
4. Upload the receipt photo. A receipt over the approved total needs the Advisor's sign-off before any reimbursement.
5. Receive the items (packs, real prices, units). Stock and average costs update only now.
6. The Advisor closes the form. A PDF copy is stored and emailed to both signers.

## Each fall: members and roles

1. New people sign in on their own with a code emailed to them. Their first sign-in makes them a **Cashier**.
2. A Super Admin opens **Members**: deactivates graduates (that also blocks their email), sets officers' roles (Advisor, President, Treasurer), and gives each new cashier a 4-digit PIN. Nobody can open a shift until a Super Admin has set their first PIN.
3. Make sure the shared **Register** account (role: Register) is active.
4. Check **Settings**: starting float, open days for the year, pre-auth limit.

To block someone, turn **Active** off on their row. They can no longer use the app, and their email can't make a new account.

## If the app stops answering after a break

Supabase Free pauses a project after a week with no activity (winter and summer break).

1. Sign in to supabase.com with the chapter account and open the project.
2. Click **Restore project** and wait for it to come back (a few minutes).
3. Reload the app.

If Netlify shows "Site not available", the team ran out of monthly credits. Check the team's usage page; it resets next month, or move to the Personal plan.

## Restoring from a backup

Weekly encrypted backups are GitHub Actions artifacts in the backend repo (kept 8 weeks). They cover the database, not uploaded files in Storage.

1. Download the newest `fbla-store-<date>.tgz.gpg` artifact from the "Weekly backup" workflow.
2. Decrypt with the Advisor's passphrase:
   `gpg --decrypt fbla-store-<date>.tgz.gpg > backup.tgz && mkdir restore && tar xzf backup.tgz -C restore`
3. Restore into an empty project (or a local `supabase start` database):
   ```sh
   psql "$TARGET_DB_URL" -f restore/roles.sql
   psql "$TARGET_DB_URL" -f restore/schema.sql
   psql "$TARGET_DB_URL" -c "set session_replication_role = replica" -f restore/data.sql
   ```
   `session_replication_role = replica` lets the data load without tripping the append-only triggers. Then run `select verify_log();` as an officer: it should report ok.
4. Members sign in again with their email codes; their accounts relink to their member rows by email.

## Handing off accounts

The Advisor owns the GitHub organization, the Supabase organization, the Netlify team, the Resend account, the domain, and the Anthropic Console account. Student developers stay on as members. The Advisor holds the Super Admin flag and assigns roles each fall.

Replace any key or password that ends up in a chat, an issue, or a commit.
