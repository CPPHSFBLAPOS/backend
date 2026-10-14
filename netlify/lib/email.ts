// Email through Resend's HTTP API. Without RESEND_API_KEY (local dev) the
// message is logged instead of sent.

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

export async function sendEmail(email: Email, fetchImpl: typeof fetch = fetch): Promise<{ sent: boolean; id?: string }> {
  const to = [...new Set(email.to.filter(Boolean))];
  if (to.length === 0) return { sent: false };
  const key = process.env.RESEND_API_KEY;
  if (!key) {
    console.log(`[email not sent: RESEND_API_KEY missing] to=${to.join(',')} subject=${email.subject}`);
    return { sent: false };
  }
  const res = await fetchImpl('https://api.resend.com/emails', {
    method: 'POST',
    headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      from: process.env.EMAIL_FROM ?? 'FBLA Store <store@example.org>',
      to,
      subject: email.subject,
      html: email.html,
      attachments: email.attachments?.map((a) => ({
        filename: a.filename,
        content: Buffer.from(a.content).toString('base64'),
      })),
    }),
  });
  if (!res.ok) {
    console.error('Resend error', res.status, await res.text());
    return { sent: false };
  }
  const body = (await res.json()) as { id?: string };
  return { sent: true, id: body.id };
}
