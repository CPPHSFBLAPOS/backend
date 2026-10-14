// Small helpers shared by every function: JSON responses, CORS, errors.
//
// In production the frontend proxies /api/* to this site, so requests are
// same-origin and CORS never comes into play. During local development the
// Vite dev server calls this site directly, so origins listed in
// ALLOWED_ORIGINS (comma separated) get CORS headers.

export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public code?: string,
  ) {
    super(message);
  }
}

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('origin');
  const allowed = (process.env.ALLOWED_ORIGINS ?? 'http://localhost:5173')
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);
  if (!origin || !allowed.includes(origin)) return {};
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-methods': 'POST, GET, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type, x-fbla-device',
    'access-control-max-age': '600',
    vary: 'origin',
  };
}

export function json(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...corsHeaders(req) },
  });
}

type Handler = (req: Request) => Promise<Response>;

// Wraps a handler with OPTIONS handling, a method check and error mapping.
// A HEAD request to a GET handler runs it as a GET and returns the status and
// headers without the body.
export function handle(methods: string[], fn: Handler): Handler {
  const run = async (req: Request): Promise<Response> => {
    try {
      return await fn(req);
    } catch (err) {
      if (err instanceof HttpError) {
        return json(req, err.status, { error: err.code ?? 'error', message: err.message });
      }
      console.error(err);
      return json(req, 500, { error: 'server_error', message: 'Something went wrong. Try again.' });
    }
  };
  return async (req) => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(req) });
    if (req.method === 'HEAD' && methods.includes('GET')) {
      const res = await run(new Request(req.url, { method: 'GET', headers: req.headers }));
      await res.body?.cancel();
      return new Response(null, { status: res.status, headers: res.headers });
    }
    if (!methods.includes(req.method)) return json(req, 405, { error: 'method_not_allowed' });
    return run(req);
  };
}

export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new HttpError(400, 'Send a JSON body.', 'bad_request');
  }
}

export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new HttpError(500, `${name} is not set on the server.`, 'not_configured');
  return value;
}
