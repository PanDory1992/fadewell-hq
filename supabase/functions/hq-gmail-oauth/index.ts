const projectUrl = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const clientId = Deno.env.get('GMAIL_CLIENT_ID')!;
const clientSecret = Deno.env.get('GMAIL_CLIENT_SECRET')!;
const redirectUri = `${projectUrl}/functions/v1/hq-gmail-oauth/callback`;
const gmailScope = 'https://www.googleapis.com/auth/gmail.readonly';
const hqSystemUrl = 'https://hq.fadewell.eu/system.html';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });

Deno.serve(async (request) => {
  const url = new URL(request.url);
  if (url.pathname.endsWith('/authorize')) {
    const google = new URL('https://accounts.google.com/o/oauth2/v2/auth');
    google.searchParams.set('client_id', clientId);
    google.searchParams.set('redirect_uri', redirectUri);
    google.searchParams.set('response_type', 'code');
    google.searchParams.set('scope', gmailScope);
    google.searchParams.set('access_type', 'offline');
    google.searchParams.set('prompt', 'consent');
    return Response.redirect(google, 302);
  }
  if (!url.pathname.endsWith('/callback')) return json({ error: 'Use /authorize to connect Gmail.' }, 404);
  const code = url.searchParams.get('code');
  if (!code) return json({ error: url.searchParams.get('error') || 'Missing OAuth code.' }, 400);
  const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code, client_id: clientId, client_secret: clientSecret, redirect_uri: redirectUri, grant_type: 'authorization_code' })
  });
  const token = await tokenResponse.json();
  if (!tokenResponse.ok || !token.refresh_token) return json({ error: 'Google token exchange failed.' }, 400);
  const profileResponse = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/profile', { headers: { authorization: `Bearer ${token.access_token}` } });
  const profile = await profileResponse.json();
  if (!profileResponse.ok || profile.emailAddress !== 'falka.falka35@gmail.com') return json({ error: 'Only falka.falka35@gmail.com may be connected.' }, 403);
  const saved = await fetch(`${projectUrl}/rest/v1/hq_email_connections?on_conflict=provider`, {
    method: 'POST', headers: { apikey: serviceKey, authorization: `Bearer ${serviceKey}`, 'content-type': 'application/json', prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({ provider: 'gmail', email: profile.emailAddress, refresh_token: token.refresh_token, scopes: [gmailScope], updated_at: new Date().toISOString() })
  });
  if (!saved.ok) return json({ error: 'Could not store the private Gmail connection.' }, 500);

  // Start a verification run now, rather than making the owner wait for the five-minute schedule.
  // The sync function records its own result; a callback failure must never undo a valid OAuth connection.
  let syncState = 'queued';
  try {
    const sync = await fetch(`${projectUrl}/functions/v1/hq-gmail-sync`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}'
    });
    if (sync.ok) syncState = 'connected';
  } catch (_) { /* System shows the scheduled sync state after redirect. */ }

  const destination = new URL(hqSystemUrl);
  destination.searchParams.set('gmail', syncState);
  return Response.redirect(destination, 303);
});

