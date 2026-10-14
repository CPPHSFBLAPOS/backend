import { handle, json } from '../lib/http.ts';

// Used by the app's home page to show that the functions are reachable.
export default handle(['GET'], async (req) =>
  json(req, 200, {
    ok: true,
    service: 'fbla-store-functions',
    time: new Date().toISOString(),
    configured: {
      supabase: Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY),
      anthropic: Boolean(process.env.ANTHROPIC_API_KEY),
      resend: Boolean(process.env.RESEND_API_KEY),
    },
  }),
);
