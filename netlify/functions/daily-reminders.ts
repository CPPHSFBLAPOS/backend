import type { Config } from '@netlify/functions';
import { appUrl, escapeHtml, layout, sendEmail } from '../lib/email.ts';
import { serviceClient } from '../lib/supabase.ts';

type Overdue = { id: string; number: number; student_name: string; receipt_due_date: string };
type Result = { newly_overdue: Overdue[]; overdue: Overdue[]; advisor_emails: string[] };

// Every morning: flag purchased forms whose receipt is past due (day 6) and
// email the Advisor the list. Nobody is signed in, so this is the one function
// that uses the service role key.
export default async function dailyReminders(): Promise<Response> {
  const supabase = serviceClient();
  const { data, error } = await supabase.rpc('mark_overdue_preauths');
  if (error) {
    console.error('mark_overdue_preauths failed', error);
    return new Response(error.message, { status: 500 });
  }
  const result = data as Result;
  if (result.overdue.length > 0) {
    const items = result.overdue
      .map((o) => {
        const isNew = result.newly_overdue.some((n) => n.id === o.id);
        return `<li><a href="${escapeHtml(appUrl(`/preauth/${o.id}`))}">Form #${o.number}</a>: ${escapeHtml(o.student_name)}, receipt was due ${escapeHtml(o.receipt_due_date)}${isNew ? ' <strong>(new today)</strong>' : ''}</li>`;
      })
      .join('');
    await sendEmail({
      to: result.advisor_emails,
      subject: `${result.overdue.length} pre-auth receipt${result.overdue.length === 1 ? ' is' : 's are'} overdue`,
      html: layout('Overdue receipts', `<p>No reimbursement can be recorded until these receipts are uploaded.</p><ul>${items}</ul>`, {
        href: appUrl('/preauth'),
        label: 'Open pre-auths',
      }),
    });
  }
  console.log(`daily-reminders: ${result.newly_overdue.length} newly overdue, ${result.overdue.length} total`);
  return new Response('ok');
}

// 12:00 UTC is 8 AM Eastern in daylight saving time and 7 AM in winter.
export const config: Config = { schedule: '0 12 * * *' };
