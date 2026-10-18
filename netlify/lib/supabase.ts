import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { HttpError, requireEnv } from './http.ts';

export type Member = {
  id: string;
  email: string;
  display_name: string;
  grade: number | null;
  role: string | null;
  is_super_admin: boolean;
  permissions: string[];
};

export type Caller = { client: SupabaseClient; member: Member; token: string };

export function bearerToken(req: Request): string | null {
  const header = req.headers.get('authorization') ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1] : null;
}

// How a function checks who's calling:
// 1. The browser sends the member's Supabase access token.
// 2. We verify it with Supabase and load the member and their permissions.
// 3. Every database call uses that same token, so row-level security and the
//    RPCs' own role checks still apply.
export async function getCaller(req: Request, permission?: string): Promise<Caller> {
  const token = bearerToken(req);
  if (!token) throw new HttpError(401, 'Sign in first.', 'unauthorized');

  const client = createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_ANON_KEY'), {
    global: {
      headers: {
        Authorization: `Bearer ${token}`,
        'x-fbla-device': req.headers.get('x-fbla-device') ?? 'netlify-function',
      },
    },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await client.auth.getUser(token);
  if (userError || !userData.user) throw new HttpError(401, 'Your sign-in expired. Sign in again.', 'unauthorized');

  const { data: member, error } = await client.rpc('whoami');
  if (error) throw new HttpError(502, error.message, 'database_error');
  if (!member) throw new HttpError(403, 'Not a member yet. Sign in with the code from your email.', 'not_member');
  const m = member as Member;
  if (permission && !m.permissions.includes(permission)) {
    throw new HttpError(403, 'You do not have permission to do that.', 'forbidden');
  }
  return { client, member: m, token };
}

// Only scheduled functions use the service role key: nobody is signed in
// when they run.
export function serviceClient(): SupabaseClient {
  return createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { 'x-fbla-device': 'daily-reminders' } },
  });
}

export async function rpc<T>(client: SupabaseClient, fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await client.rpc(fn, args);
  if (error) {
    const status = error.code === '42501' ? 403 : 400;
    throw new HttpError(status, error.message, error.code ?? 'database_error');
  }
  return data as T;
}
