import { PDFDocument } from 'pdf-lib';
import { describe, expect, it } from 'vitest';
import { drawPreauthPdf, safe, type PdfPreauth } from '../netlify/lib/pdf.ts';

const form: PdfPreauth = {
  number: 12,
  status: 'closed',
  student_name: 'Taylor Treasurer (test)',
  grade: 11,
  fbla_role: 'Treasurer',
  request_date: '2026-10-01',
  vendor: "Sam's Club",
  website: 'https://www.samsclub.com',
  purposes: ['fundraiser', 'other'],
  purpose_other: 'Homecoming stand',
  justification: 'Water and chips sell out every week. “Smart quotes” and an emoji 🎉 should not break the PDF.',
  shipping_cents: 0,
  lines_total_cents: 1800,
  grand_total_cents: 1800,
  approved_total_cents: 1800,
  purchase_date: '2026-10-03',
  receipt_due_date: '2026-10-08',
  receipts_total_cents: 1890,
  reimbursed_cents: 1890,
  reimbursed_to: 'Taylor Treasurer (test)',
  notes: null,
  hash: 'f'.repeat(64),
  lines: [
    {
      line_no: 1,
      product_name: 'Water Bottle 16.9 oz',
      new_name: null,
      item_number: '980012345',
      url: 'https://www.samsclub.com/ip/x/980012345',
      units_per_pack: 24,
      packs: 2,
      est_pack_price_cents: 600,
      sell_price_cents: 100,
      packs_bought: 2,
      actual_pack_price_cents: 600,
      units_received: 48,
      received_unit_cost_cents: 26,
    },
    {
      line_no: 2,
      product_name: null,
      new_name: 'Highlighters',
      item_number: null,
      url: null,
      units_per_pack: 12,
      packs: 1,
      est_pack_price_cents: 600,
      sell_price_cents: 100,
      packs_bought: null,
      actual_pack_price_cents: null,
      units_received: null,
      received_unit_cost_cents: null,
    },
  ],
  signatures: [
    {
      role: 'student',
      typed_name: 'Taylor Treasurer',
      signed_at: '2026-10-01T14:00:00Z',
      strokes: [{ points: [{ x: 0, y: 0 }, { x: 40, y: 20 }, { x: 80, y: 5 }] }],
      voided_at: null,
    },
    {
      role: 'advisor',
      typed_name: 'Avery Advisor',
      signed_at: '2026-10-02T14:00:00Z',
      strokes: [{ points: [{ x: 5, y: 5 }] }],
      voided_at: null,
    },
  ],
};

describe('pre-auth PDF', () => {
  it('draws the form and Attachment A', async () => {
    const bytes = await drawPreauthPdf(form);
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe('%PDF-');
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBe(2);
    expect(doc.getTitle()).toBe('Preauthorization Purchase Order Form #12');
  });

  it('keeps text inside the standard font encoding', () => {
    expect(safe('“Hi” — it’s 🎉')).toBe('"Hi" - it\'s ??');
  });
});
