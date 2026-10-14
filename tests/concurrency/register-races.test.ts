// Two registers at once, against a real database (committed transactions).
//   supabase start && npm run test:concurrency
// or point DATABASE_URL at any database with the migrations and seed loaded.
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const url = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';

async function session(email: string) {
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  const { rows } = await client.query(
    `with existing as (select id from auth.users where lower(email) = lower($1)),
          created as (insert into auth.users (id, email)
                      select gen_random_uuid(), lower($1) where not exists (select 1 from existing)
                      returning id)
     select id from existing union all select id from created`,
    [email],
  );
  const uid = rows[0].id as string;
  return {
    client,
    async begin() {
      await client.query('begin');
      await client.query(`select set_config('request.jwt.claims', $1, true)`, [
        JSON.stringify({ sub: uid, role: 'authenticated', email }),
      ]);
      await client.query('set local role authenticated');
    },
    async run<T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T> {
      await this.begin();
      try {
        const res = await client.query(sql, params);
        await client.query('commit');
        return res.rows[0] as T;
      } catch (err) {
        await client.query('rollback');
        throw err;
      }
    },
  };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe('two registers at once', () => {
  let a: Awaited<ReturnType<typeof session>>;
  let b: Awaited<ReturnType<typeof session>>;
  let shiftId: string;
  let water: string;

  beforeAll(async () => {
    a = await session('register@example.com');
    b = await session('register@example.com');
    const cashier = await a.client.query(`select id from members where email = 'cashier2@example.com'`);
    // Close any shift a previous run left open.
    await a.client.query(`update shifts set closed_at = now() where closed_at is null and cashier_id = $1`, [cashier.rows[0].id]);
    const opened = await a.run<{ r: { shift_id: string } }>(`select open_shift($1, '4444', 0) as r`, [cashier.rows[0].id]);
    shiftId = opened.r.shift_id;
    water = (await a.client.query(`select id from products where sku = 'FBLA-0001'`)).rows[0].id;
  });

  afterAll(async () => {
    await a?.client.query(`update shifts set closed_at = now() where id = $1`, [shiftId]).catch(() => {});
    await a?.client.end();
    await b?.client.end();
  });

  it('cannot overdraw a gift card from two registers', async () => {
    const loaded = await a.run<{ r: { new_cards: Array<{ code: string }> } }>(
      `select complete_sale(gen_random_uuid(), $1, 'regular', '[{"kind": "gift_card_load", "amount_cents": 500}]',
                            '[{"method": "cash", "amount_cents": 500}]') as r`,
      [shiftId],
    );
    const code = loaded.r.new_cards[0].code;
    const spend = (s: typeof a) =>
      s.client.query(
        `select complete_sale(gen_random_uuid(), $1, 'regular', $2::jsonb, $3::jsonb) as r`,
        [
          shiftId,
          JSON.stringify([{ kind: 'product', product_id: water, qty: 4 }]),
          JSON.stringify([{ method: 'gift_card', code, amount_cents: 400 }]),
        ],
      );

    // Register A spends $4.00 and holds its transaction open; register B tries
    // the same card while A still has the row locked.
    await a.begin();
    await b.begin();
    await spend(a);
    const second = spend(b).then(
      () => 'ok',
      (err: Error) => err.message,
    );
    await sleep(300);
    await a.client.query('commit');
    const outcome = await second;
    await b.client.query(outcome === 'ok' ? 'commit' : 'rollback');

    expect(outcome).toMatch(/only has \$1\.00/);
    const balance = await a.client.query(
      `select coalesce(sum(t.amount_cents), 0)::int as cents from gift_card_txns t
       join gift_cards c on c.id = t.card_id where c.code = $1`,
      [code],
    );
    expect(balance.rows[0].cents).toBe(100);
  });

  it('saves a sale once when both copies arrive together', async () => {
    const clientUuid = crypto.randomUUID();
    const send = (s: typeof a) =>
      s.run<{ r: { duplicate: boolean } }>(
        `select complete_sale($1, $2, 'regular', $3::jsonb, '[{"method": "cash", "amount_cents": 100}]') as r`,
        [clientUuid, shiftId, JSON.stringify([{ kind: 'product', product_id: water, qty: 1 }])],
      );
    const results = await Promise.all([send(a), send(b)]);
    expect(results.map((r) => r.r.duplicate).sort()).toEqual([false, true]);
    const count = await a.client.query(`select count(*)::int as n from sales where client_uuid = $1`, [clientUuid]);
    expect(count.rows[0].n).toBe(1);
  });
});
