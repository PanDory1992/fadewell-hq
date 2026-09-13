const projectUrl = Deno.env.get('SUPABASE_URL')!;
const cronSecret = Deno.env.get('VINTED_COLLECTOR_CRON_SECRET')!;
const githubToken = Deno.env.get('GITHUB_WORKFLOW_DISPATCH_TOKEN')!;
const repository = 'PanDory1992/fadewell-hq';
const workflows = new Set(['storefront-sync.yml', 'gmail-sync-watchdog.yml']);

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
});

async function sameSecret(left: string, right: string) {
  if (!left || !right) return false;
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(left)),
    crypto.subtle.digest('SHA-256', encoder.encode(right)),
  ]);
  return new Uint8Array(a).every((value, index) => value === new Uint8Array(b)[index]);
}

Deno.serve(async request => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed.' }, 405);
  const supplied = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!await sameSecret(supplied, cronSecret)) return json({ error: 'Forbidden.' }, 403);
  if (!githubToken) return json({ error: 'GitHub workflow token is not configured.' }, 503);

  const payload = await request.json().catch(() => ({}));
  const workflow = String(payload?.workflow || '');
  if (!workflows.has(workflow)) return json({ error: 'Unsupported workflow.' }, 400);

  const response = await fetch(
    `https://api.github.com/repos/${repository}/actions/workflows/${workflow}/dispatches`,
    {
      method: 'POST',
      headers: {
        accept: 'application/vnd.github+json',
        authorization: `Bearer ${githubToken}`,
        'content-type': 'application/json',
        'user-agent': 'fadewell-hq-supabase-scheduler',
        'x-github-api-version': '2022-11-28',
      },
      body: JSON.stringify({ ref: 'main' }),
      signal: AbortSignal.timeout(15_000),
    },
  ).catch(error => new Response(String(error), { status: 599 }));

  if (!response.ok) {
    const detail = (await response.text()).replace(/\s+/g, ' ').slice(0, 500);
    return json({ error: `GitHub workflow dispatch HTTP ${response.status}: ${detail}` }, 502);
  }
  return json({ dispatched: true, workflow, scheduler: projectUrl }, 202);
});
