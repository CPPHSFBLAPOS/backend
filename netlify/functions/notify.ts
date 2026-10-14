import { HttpError, handle, json, readJson } from '../lib/http.ts';
import { appUrl, escapeHtml, layout, sendEmail } from '../lib/email.ts';
import { formatCents } from '../lib/money.ts';
import { getCaller, rpc } from '../lib/supabase.ts';

type Contacts = {
  id: string;
  number: number;
  status: string;
  student_name: string;
  grand_total_cents: number;
  reject_comment: string | null;
  requester_email: string;
  advisor_emails: string[];
};

// Each event only makes sense in one status. Re-checking it here means a
// stale or replayed request cannot send a misleading email.
const EXPECTED: Record<string, string> = {
  submitted: 'awaiting_advisor',
  approved: 'approved',
  rejected: 'rejected',
};

// POST { preauth_id, event: 'submitted' | 'approved' | 'rejected' }
export default handle(['POST'], async (req) => {
  const { client } = await getCaller(req, 'preauth_view');
  const { preauth_id, event } = await readJson<{ preauth_id?: string; event?: string }>(req);
  if (!preauth_id || !event || !(event in EXPECTED)) throw new HttpError(400, 'Unknown notification.', 'bad_request');

  const c = await rpc<Contacts>(client, 'preauth_contacts', { p_id: preauth_id });
  if (c.status !== EXPECTED[event]) {
    throw new HttpError(409, `Form #${c.number} is ${c.status.replace(/_/g, ' ')}, not ${EXPECTED[event].replace(/_/g, ' ')}.`, 'stale');
  }

  const link = { href: appUrl(`/preauth/${c.id}`), label: `Open form #${c.number}` };
  const total = formatCents(c.grand_total_cents);
  const name = escapeHtml(c.student_name);
  let to: string[];
  let subject: string;
  let html: string;

  if (event === 'submitted') {
    to = c.advisor_emails;
    subject = `Pre-auth #${c.number} is waiting for your approval (${total})`;
    html = layout(subject, `<p>${name} signed Preauthorization Purchase Order Form #${c.number} for ${total}. Review the items and payoff, then approve or reject it.</p>`, link);
  } else if (event === 'approved') {
    to = [c.requester_email];
    subject = `Pre-auth #${c.number} was approved`;
    html = layout(subject, `<p>The Advisor approved form #${c.number} for ${total}. You can make the purchase. The receipt is due 5 days after the purchase date.</p>`, link);
  } else {
    to = [c.requester_email];
    subject = `Pre-auth #${c.number} needs changes`;
    html = layout(subject, `<p>The Advisor sent form #${c.number} back:</p><blockquote style="border-left:3px solid #cbd5e1;margin:0;padding-left:12px">${escapeHtml(c.reject_comment ?? '')}</blockquote><p>Edit it and sign again to resubmit.</p>`, link);
  }

  const result = await sendEmail({ to, subject, html });
  return json(req, 200, { ok: true, sent: result.sent, recipients: to.length });
});
