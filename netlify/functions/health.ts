import { emailConfigured } from '../lib/email.ts';
import { handle, json } from '../lib/http.ts';

// Used by the app's home page to show that the functions are reachable, and
// by the deploy check in the README: every flag should be true in production.
// app_url is false while email links would still point at localhost.
export default handle(['GET'], async (req) =>
  json(req, 200, {
    ok: true,
    service: 'fbla-store-functions',
    time: new Date().toISOString(),
    configured: {
      supabase: Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY),
      service_role: Boolean(process.env.SUPABASE_SERVICE_ROLE_KEY),
      anthropic: Boolean(process.env.ANTHROPIC_API_KEY),
      // Email works through Brevo or Resend; the app reads this flag as "Email".
      resend: emailConfigured(),
      app_url: isPublicUrl(process.env.APP_URL),
    },
  }),
);

function isPublicUrl(url: string | undefined): boolean {
  return /^https:\/\//.test(url ?? '') && !/localhost|127\.0\.0\.1/.test(url ?? '');
}
