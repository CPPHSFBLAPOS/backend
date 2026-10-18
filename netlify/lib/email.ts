// Email through Brevo's or Resend's HTTP API, whichever key is set (Brevo
// first). Without either key (local dev) the message is logged instead of
// sent. EMAIL_FROM is "Name <address>"; with Brevo the address must be a
// verified sender in the Brevo account.

export type Attachment = { filename: string; content: Uint8Array };
export type Email = { to: string[]; subject: string; html: string; attachments?: Attachment[] };

export function appUrl(path = ''): string {
  const base = (process.env.APP_URL ?? 'http://localhost:5173').replace(/\/+$/, '');
  return `${base}${path}`;
}

export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function layout(title: string, body: string, link?: { href: string; label: string }): string {
  const button = link
    ? `<p style="margin:24px 0"><a href="${escapeHtml(link.href)}" style="background:#1d4ed8;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:600">${escapeHtml(link.label)}</a></p>`
    : '';
  return `<!doctype html><html><body style="font-family:system-ui,-apple-system,Segoe UI,sans-serif;color:#0f172a;max-width:560px;margin:0 auto;padding:24px">
<h2 style="margin:0 0 12px">${escapeHtml(title)}</h2>${body}${button}
<p style="color:#64748b;font-size:12px;margin-top:32px">CPPHS FBLA Store</p></body></html>`;
}

export function parseFrom(from: string): { name?: string; email: string } {
  const m = from.match(/^\s*"?([^"<]*?)"?\s*<\s*([^>\s]+)\s*>\s*$/);
  if (m) return m[1].trim() ? { name: m[1].trim(), email: m[2] } : { email: m[2] };
  return { email: from.trim() };
}

export function emailConfigured(): boolean {
  return Boolean(process.env.BREVO_API_KEY || process.env.RESEND_API_KEY);
}

export async function sendEmail(email: Email, fetchImpl: typeof fetch = fetch): Promise<{ sent: boolean; id?: string }> {
  const to = [...new Set(email.to.filter(Boolean))];
  if (to.length === 0) return { sent: false };
  const from = process.env.EMAIL_FROM ?? 'FBLA Store <store@example.org>';
  const attachments = email.attachments?.map((a) => ({
    filename: a.filename,
    content: Buffer.from(a.content).toString('base64'),
  }));

  const brevoKey = process.env.BREVO_API_KEY;
  if (brevoKey) {
    const res = await fetchImpl('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': brevoKey, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({
        sender: parseFrom(from),
        to: to.map((address) => ({ email: address })),
        subject: email.subject,
        htmlContent: email.html,
        ...(attachments?.length ? { attachment: attachments.map((a) => ({ name: a.filename, content: a.content })) } : {}),
      }),
    });
    if (!res.ok) {
      console.error('Brevo error', res.status, await res.text());
      return { sent: false };
    }
    const body = (await res.json()) as { messageId?: string };
    return { sent: true, id: body.messageId };
  }

  const key = process.env.RESEND_API_KEY;
  if (!key) {
    console.log(`[email not sent: no BREVO_API_KEY or RESEND_API_KEY] to=${to.join(',')} subject=${email.subject}`);
    return { sent: false };
  }
  const res = await fetchImpl('https://api.resend.com/emails', {
    method: 'POST',
    headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify({ from, to, subject: email.subject, html: email.html, attachments }),
  });
  if (!res.ok) {
    console.error('Resend error', res.status, await res.text());
    return { sent: false };
  }
  const body = (await res.json()) as { id?: string };
  return { sent: true, id: body.id };
}
