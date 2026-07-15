const projectUrl = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const githubToken = Deno.env.get('GITHUB_WORKFLOW_DISPATCH_TOKEN');
const cors = {
  'access-control-allow-origin': 'https://hq.fadewell.eu',
  'access-control-allow-headers': 'authorization, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
  'content-type': 'application/json'
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });
const github = (path: string, init: RequestInit = {}) => fetch(`https://api.github.com${path}`, {
  ...init,
  headers: {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    Authorization: `Bearer ${githubToken}`,
    ...(init.headers || {})
  }
});

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (request.method !== 'POST') return reply({ error: 'Method not allowed.' }, 405);
  const authorization = request.headers.get('authorization') || '';
  if (!/^Bearer\s+.+/i.test(authorization)) return reply({ error: 'Authentication is required.' }, 401);

  const ownerCheck = await fetch(`${projectUrl}/rest/v1/rpc/is_hq_owner`, {
    method: 'POST', headers: { apikey: serviceKey, authorization, 'content-type': 'application/json' }, body: '{}'
  });
  if (!ownerCheck.ok || !(await ownerCheck.json())) return reply({ error: 'HQ owner access is required.' }, 403);
  if (!githubToken) return reply({ error: 'Manual collector trigger is not configured.' }, 503);

  const active = await github('/repos/PanDory1992/fadewell-hq/actions/workflows/vinted-cloud-sync.yml/runs?per_page=20');
  if (!active.ok) return reply({ error: 'Could not inspect collector status.' }, 502);
  const activeRun = (await active.json()).workflow_runs?.find((run: { status: string; html_url: string }) => run.status !== 'completed');
  if (activeRun) return reply({ status: 'already_running', run_url: activeRun.html_url });

  const dispatched = await github('/repos/PanDory1992/fadewell-hq/actions/workflows/vinted-cloud-sync.yml/dispatches', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ref: 'main' })
  });
  if (!dispatched.ok) return reply({ error: 'Could not start collector.' }, 502);
  return reply({ status: 'started' }, 202);
});
