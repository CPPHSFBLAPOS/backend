// Draws the Preauthorization Purchase Order Form as a PDF laid out like the
// paper form, with Attachment A listing the items and their payoff.

import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from 'pdf-lib';
import { formatCents } from './money.ts';
import { lineRoi, percent, totalRoi } from './roi.ts';

export type StrokePoint = { x: number; y: number };
export type Stroke = { points: StrokePoint[] };

export type PdfSignature = {
  role: string;
  typed_name: string;
  signed_at: string;
  strokes: Stroke[];
  voided_at: string | null;
};

export type PdfLine = {
  line_no: number;
  product_name: string | null;
  new_name: string | null;
  item_number: string | null;
  url: string | null;
  units_per_pack: number;
  packs: number;
  est_pack_price_cents: number;
  sell_price_cents: number;
  packs_bought: number | null;
  actual_pack_price_cents: number | null;
  units_received: number | null;
  received_unit_cost_cents: number | null;
};

export type PdfPreauth = {
  number: number;
  status: string;
  student_name: string;
  grade: number | null;
  fbla_role: string | null;
  request_date: string;
  vendor: string;
  website: string | null;
  purposes: string[];
  purpose_other: string | null;
  justification: string | null;
  shipping_cents: number;
  lines_total_cents: number;
  grand_total_cents: number;
  approved_total_cents: number | null;
  purchase_date: string | null;
  receipt_due_date: string | null;
  receipts_total_cents: number;
  reimbursed_cents: number | null;
  reimbursed_to: string | null;
  notes: string | null;
  hash: string;
  lines: PdfLine[];
  signatures: PdfSignature[];
};

const INK = rgb(0.06, 0.09, 0.16);
const MUTED = rgb(0.39, 0.45, 0.55);
const RULE = rgb(0.8, 0.83, 0.88);
const ACCENT = rgb(0.11, 0.3, 0.85);

// Standard PDF fonts only cover WinAnsi; swap anything else for a safe stand-in.
export function safe(text: string | null | undefined): string {
  return (text ?? '')
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, '-')
    .replace(/…/g, '...')
    .replace(/[^\x20-\x7E\xA0-\xFF\n]/g, '?');
}

function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
  const out: string[] = [];
  for (const paragraph of safe(text).split('\n')) {
    let line = '';
    for (const word of paragraph.split(/\s+/)) {
      const next = line ? `${line} ${word}` : word;
      if (font.widthOfTextAtSize(next, size) > width && line) {
        out.push(line);
        line = word;
      } else {
        line = next;
      }
    }
    out.push(line);
  }
  return out;
}

function fit(text: string, font: PDFFont, size: number, width: number): string {
  let t = safe(text);
  if (font.widthOfTextAtSize(t, size) <= width) return t;
  while (t.length > 1 && font.widthOfTextAtSize(`${t}...`, size) > width) t = t.slice(0, -1);
  return `${t}...`;
}

function drawSignature(page: PDFPage, strokes: Stroke[], x: number, y: number, w: number, h: number) {
  const points = strokes.flatMap((s) => s.points ?? []);
  if (points.length === 0) return;
  const minX = Math.min(...points.map((p) => p.x));
  const maxX = Math.max(...points.map((p) => p.x));
  const minY = Math.min(...points.map((p) => p.y));
  const maxY = Math.max(...points.map((p) => p.y));
  const scale = Math.min(w / Math.max(maxX - minX, 1), h / Math.max(maxY - minY, 1));
  const ox = x + (w - (maxX - minX) * scale) / 2;
  const oy = y + (h - (maxY - minY) * scale) / 2;
  for (const stroke of strokes) {
    const pts = stroke.points ?? [];
    for (let i = 1; i < pts.length; i++) {
      page.drawLine({
        start: { x: ox + (pts[i - 1].x - minX) * scale, y: oy + (maxY - pts[i - 1].y) * scale },
        end: { x: ox + (pts[i].x - minX) * scale, y: oy + (maxY - pts[i].y) * scale },
        thickness: 1.2,
        color: INK,
      });
    }
    if (pts.length === 1) {
      page.drawCircle({ x: ox + (pts[0].x - minX) * scale, y: oy + (maxY - pts[0].y) * scale, size: 0.8, color: INK });
    }
  }
}

function shortDate(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso.length === 10 ? `${iso}T12:00:00` : iso);
  return d.toLocaleDateString('en-US', { timeZone: 'America/New_York', month: '2-digit', day: '2-digit', year: 'numeric' });
}

export async function drawPreauthPdf(form: PdfPreauth): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.setTitle(`Preauthorization Purchase Order Form #${form.number}`);
  doc.setAuthor('CPPHS FBLA Store');
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  const page = doc.addPage([612, 792]);
  const left = 48;
  const right = 564;
  let y = 744;

  const text = (t: string, x: number, yy: number, size = 10, f: PDFFont = font, color = INK) =>
    page.drawText(safe(t), { x, y: yy, size, font: f, color });
  const rule = (yy: number) => page.drawLine({ start: { x: left, y: yy }, end: { x: right, y: yy }, thickness: 0.75, color: RULE });
  const section = (title: string) => {
    y -= 22;
    page.drawRectangle({ x: left, y: y - 4, width: right - left, height: 18, color: rgb(0.94, 0.95, 0.98) });
    text(title.toUpperCase(), left + 6, y + 1, 9, bold, ACCENT);
    y -= 18;
  };
  const field = (label: string, value: string, x: number, width: number) => {
    text(label, x, y + 12, 7.5, font, MUTED);
    text(fit(value, font, 10, width - 4), x, y, 10);
    page.drawLine({ start: { x, y: y - 3 }, end: { x: x + width - 8, y: y - 3 }, thickness: 0.5, color: RULE });
  };

  text('Corning-Painted Post High School FBLA', left, y, 10, font, MUTED);
  text(`Form #${form.number}`, right - 80, y, 10, bold);
  y -= 22;
  text('Preauthorization Purchase Order Form', left, y, 18, bold);
  y -= 8;
  rule(y);

  section('Student Information');
  field('Name', form.student_name, left, 230);
  field('Grade', form.grade ? String(form.grade) : '', left + 230, 70);
  field('FBLA Role', form.fbla_role ?? '', left + 300, 110);
  field('Date of Request', shortDate(form.request_date), left + 410, 106);
  y -= 8;

  section('Item(s) to be Purchased');
  const cols = [left, left + 22, left + 250, left + 320, left + 365, left + 420, left + 470];
  const heads = ['#', 'Item', 'Item #', 'Packs', 'Units/pk', 'Est. price', 'Total'];
  heads.forEach((h, i) => text(h, cols[i], y, 7.5, bold, MUTED));
  y -= 14;
  for (const l of form.lines) {
    const name = l.product_name ?? l.new_name ?? '';
    text(String(l.line_no), cols[0], y, 9);
    text(fit(name, font, 9, 222), cols[1], y, 9);
    text(fit(l.item_number ?? '', font, 9, 66), cols[2], y, 9);
    text(String(l.packs), cols[3], y, 9);
    text(String(l.units_per_pack), cols[4], y, 9);
    text(formatCents(l.est_pack_price_cents), cols[5], y, 9);
    text(formatCents(l.packs * l.est_pack_price_cents), cols[6], y, 9);
    y -= 13;
    if (y < 330) break;
  }
  y -= 4;
  field('Vendor/Store', form.vendor, left, 200);
  field('Website', form.website ?? '', left + 200, 316);
  y -= 6;

  section('Purpose');
  const purposes = ['competition', 'event', 'fundraiser', 'supplies', 'other'];
  let px = left;
  for (const p of purposes) {
    page.drawRectangle({ x: px, y: y - 2, width: 10, height: 10, borderColor: INK, borderWidth: 0.75 });
    if (form.purposes.includes(p)) text('X', px + 2, y, 9, bold);
    const label = p === 'other' ? `Other: ${form.purpose_other ?? ''}` : p[0].toUpperCase() + p.slice(1);
    text(fit(label, font, 10, 200), px + 15, y, 10);
    px += p === 'other' ? 0 : 92;
  }
  y -= 6;

  section('Justification');
  const roi = totalRoi(form.lines.map((l) => ({
    units_per_pack: l.units_per_pack,
    packs: l.packs,
    pack_price_cents: l.est_pack_price_cents,
    sell_price_cents: l.sell_price_cents,
  })));
  for (const line of wrap(form.justification ?? '', font, 10, right - left).slice(0, 5)) {
    text(line, left, y, 10);
    y -= 13;
  }
  text(
    `Payoff: cost ${formatCents(roi.cost_cents)}, revenue ${formatCents(roi.revenue_cents)}, profit ${formatCents(roi.profit_cents)}, ROI ${percent(roi.roi)}. See Attachment A.`,
    left, y, 9, font, MUTED,
  );
  y -= 6;

  section('Cost Information');
  field('Estimated cost of items', formatCents(form.lines_total_cents), left, 170);
  field('Shipping', formatCents(form.shipping_cents), left + 170, 110);
  field('Grand total', formatCents(form.grand_total_cents), left + 280, 120);
  field('Approved total', form.approved_total_cents === null ? '' : formatCents(form.approved_total_cents), left + 400, 116);
  y -= 6;

  section('Approvals');
  const sigBox = (role: string, label: string, x: number) => {
    const sig = form.signatures.find((s) => s.role === role && !s.voided_at);
    page.drawRectangle({ x, y: y - 52, width: 240, height: 56, borderColor: RULE, borderWidth: 0.75 });
    if (sig) drawSignature(page, sig.strokes, x + 8, y - 46, 224, 44);
    text(`${label}: ${sig?.typed_name ?? ''}`, x, y - 64, 9);
    text(`Date: ${sig ? shortDate(sig.signed_at) : ''}`, x + 170, y - 64, 9);
  };
  sigBox('student', 'Student', left);
  sigBox('advisor', 'Advisor', left + 276);
  y -= 80;

  section('Notes');
  for (const line of wrap(form.notes ?? '', font, 10, right - left).slice(0, 3)) {
    text(line, left, y, 10);
    y -= 13;
  }

  text(`Form hash (SHA-256): ${form.hash}`, left, 34, 6.5, font, MUTED);
  text(`Status: ${form.status.replace(/_/g, ' ')}   Printed ${shortDate(new Date().toISOString())}`, left, 24, 6.5, font, MUTED);

  // Attachment A
  const a = doc.addPage([612, 792]);
  let ay = 744;
  const at = (t: string, x: number, size = 9, f: PDFFont = font, color = INK) =>
    a.drawText(safe(t), { x, y: ay, size, font: f, color });
  at(`Attachment A  -  Form #${form.number}`, left, 10, font, MUTED);
  ay -= 22;
  at('Items and payoff', left, 16, bold);
  ay -= 24;
  const acols = [left, left + 160, left + 205, left + 260, left + 312, left + 368, left + 420, left + 462, left + 506];
  ['Item', 'Units', 'Cost', 'Sell', 'Revenue', 'Profit', 'ROI', 'Margin', 'Break-even'].forEach((h, i) =>
    at(h, acols[i], 7.5, bold, MUTED),
  );
  ay -= 14;
  for (const l of form.lines) {
    const r = lineRoi({
      units_per_pack: l.units_per_pack,
      packs: l.packs,
      pack_price_cents: l.est_pack_price_cents,
      sell_price_cents: l.sell_price_cents,
    });
    at(fit(l.product_name ?? l.new_name ?? '', font, 9, 152), acols[0]);
    at(String(r.units), acols[1]);
    at(formatCents(r.cost_cents), acols[2]);
    at(formatCents(l.sell_price_cents), acols[3]);
    at(formatCents(r.revenue_cents), acols[4]);
    at(formatCents(r.profit_cents), acols[5]);
    at(percent(r.roi), acols[6]);
    at(percent(r.margin), acols[7]);
    at(percent(r.break_even), acols[8]);
    ay -= 13;
  }
  a.drawLine({ start: { x: left, y: ay + 8 }, end: { x: right, y: ay + 8 }, thickness: 0.75, color: RULE });
  ay -= 4;
  at('Total', acols[0], 9, bold);
  at(String(roi.units), acols[1], 9, bold);
  at(formatCents(roi.cost_cents), acols[2], 9, bold);
  at(formatCents(roi.revenue_cents), acols[4], 9, bold);
  at(formatCents(roi.profit_cents), acols[5], 9, bold);
  at(percent(roi.roi), acols[6], 9, bold);
  at(percent(roi.margin), acols[7], 9, bold);
  at(percent(roi.break_even), acols[8], 9, bold);
  ay -= 22;
  if (roi.break_even !== null) {
    at(`Money back after selling ${percent(roi.break_even)} of it.`, left, 10);
    ay -= 24;
  }

  if (form.purchase_date) {
    at('Purchase and receiving', left, 12, bold);
    ay -= 18;
    at(`Purchased ${shortDate(form.purchase_date)}. Receipt due ${shortDate(form.receipt_due_date)}. Receipts total ${formatCents(form.receipts_total_cents)}.`, left);
    ay -= 14;
    if (form.reimbursed_cents) {
      at(`Reimbursed ${formatCents(form.reimbursed_cents)} to ${form.reimbursed_to ?? ''}.`, left);
      ay -= 14;
    }
    const received = form.lines.filter((l) => l.units_received !== null);
    if (received.length > 0) {
      ay -= 6;
      ['Item', 'Packs bought', 'Actual pack price', 'Units received', 'Unit cost'].forEach((h, i) =>
        at(h, [left, left + 200, left + 290, left + 390, left + 480][i], 7.5, bold, MUTED),
      );
      ay -= 14;
      for (const l of received) {
        at(fit(l.product_name ?? l.new_name ?? '', font, 9, 190), left);
        at(String(l.packs_bought ?? ''), left + 200);
        at(formatCents(l.actual_pack_price_cents), left + 290);
        at(String(l.units_received ?? ''), left + 390);
        at(formatCents(l.received_unit_cost_cents), left + 480);
        ay -= 13;
      }
    }
  }

  return doc.save();
}
