// Forwards a request untouched to the real Anthropic API, swapping the proxy's
// placeholder auth for the user's claude.ai OAuth token. Used whenever the
// requested model is a Claude model, so /model can switch back and forth.

const { accessToken } = require('./claude-auth');

const BASE = (process.env.ANTHROPIC_UPSTREAM_URL || 'https://api.anthropic.com').replace(/\/$/, '');

// Hop-by-hop and proxy-specific headers we must not forward.
// `expect` in particular is rejected outright by undici's fetch.
const DROP = new Set([
  'host', 'connection', 'content-length', 'authorization', 'x-api-key',
  'accept-encoding', 'transfer-encoding', 'expect', 'te', 'upgrade',
  'keep-alive', 'proxy-authorization', 'proxy-connection',
]);

async function send(path, rawBody, clientHeaders, force) {
  const token = await accessToken({ force });
  const headers = {};
  for (const [k, v] of Object.entries(clientHeaders || {})) {
    if (!DROP.has(k.toLowerCase())) headers[k] = v;
  }
  headers['content-type'] = 'application/json';
  headers.authorization = `Bearer ${token}`;
  if (!headers['anthropic-version']) headers['anthropic-version'] = '2023-06-01';

  // OAuth tokens require the oauth beta flag alongside whatever the client sent.
  const betas = new Set(
    String(headers['anthropic-beta'] || '').split(',').map((s) => s.trim()).filter(Boolean),
  );
  betas.add('oauth-2025-04-20');
  headers['anthropic-beta'] = [...betas].join(',');

  return fetch(`${BASE}${path}`, { method: 'POST', headers, body: rawBody });
}

// Streams the upstream response straight through to `res`, bytes unchanged.
async function forward(path, rawBody, clientHeaders, res, log) {
  let upstream = await send(path, rawBody, clientHeaders, false);
  if (upstream.status === 401) {
    log('401 from anthropic, forcing token refresh');
    upstream = await send(path, rawBody, clientHeaders, true);
  }

  const headers = {};
  for (const [k, v] of upstream.headers.entries()) {
    if (['content-encoding', 'content-length', 'transfer-encoding', 'connection'].includes(k)) continue;
    headers[k] = v;
  }
  res.writeHead(upstream.status, headers);

  if (!upstream.body) return res.end();
  const reader = upstream.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    res.write(Buffer.from(value));
  }
  res.end();
}

module.exports = { forward };
