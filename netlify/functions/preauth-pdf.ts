import { HttpError, handle, json, readJson } from '../lib/http.ts';
import { appUrl, layout, sendEmail } from '../lib/email.ts';
import { drawPreauthPdf, type PdfPreauth } from '../lib/pdf.ts';
import { getCaller, rpc } from '../lib/supabase.ts';

type Contacts = { number: number; signer_emails: string[] };

// POST { preauth_id, stage: 'approved' | 'closed', email?: boolean }
// Draws the signed form, stores it in the private preauth-pdfs bucket with the
// member's own token, records the path, and emails it to both signers.
export default handle(['POST'], async (req) => {
  const { client } = await getCaller(req, 'preauth_view');
  const { preauth_id, stage = 'approved', email = true } = await readJson<{
    preauth_id?: string;
    stage?: string;
    email?: boolean;
  }>(req);
  if (!preauth_id) throw new HttpError(400, 'Which form?', 'bad_request');

  const form = await rpc<PdfPreauth>(client, 'get_preauth', { p_id: preauth_id });
  const allowed = stage === 'closed' ? ['closed'] : ['approved', 'purchased', 'received', 'closed'];
  if (!allowed.includes(form.status)) {
    throw new HttpError(409, `Form #${form.number} is ${form.status.replace(/_/g, ' ')}.`, 'stale');
  }

  const bytes = await drawPreauthPdf(form);
  const path = `${preauth_id}/preauth-${form.number}-${stage}-${Date.now()}.pdf`;
  const { error } = await client.storage.from('preauth-pdfs').upload(path, bytes, {
    contentType: 'application/pdf',
    upsert: false,
  });
  if (error) throw new HttpError(502, `Could not store the PDF: ${error.message}`, 'storage_error');
  await rpc(client, 'set_preauth_pdf', { p_id: preauth_id, p_path: path });

  let sent = false;
  if (email) {
    const contacts = await rpc<Contacts>(client, 'preauth_contacts', { p_id: preauth_id });
    const subject = `Signed copy: Pre-auth #${form.number}${stage === 'closed' ? ' (closed)' : ''}`;
    const result = await sendEmail({
      to: contacts.signer_emails,
      subject,
      html: layout(subject, '<p>Your signed copy of the Preauthorization Purchase Order Form is attached. Keep it for your records.</p>', {
        href: appUrl(`/preauth/${preauth_id}`),
        label: 'Open the form',
      }),
      attachments: [{ filename: `preauth-${form.number}.pdf`, content: bytes }],
    });
    sent = result.sent;
  }
  return json(req, 200, { ok: true, path, emailed: sent });
});
