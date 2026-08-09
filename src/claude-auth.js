// Reads (and refreshes) the Claude Code OAuth credentials in
// ~/.claude/.credentials.json.
//
// Claude Code normally refreshes these itself, but once ANTHROPIC_BASE_URL is
// pointed at this proxy the CLI stops managing them -- so we have to.

const fs = require('fs');
const os = require('os');
const path = require('path');

const CRED_PATH = process.env.CLAUDE_CREDENTIALS_PATH
  || path.join(os.homedir(), '.claude', '.credentials.json');
const CLIENT_ID = process.env.CLAUDE_CLIENT_ID || '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const TOKEN_URL = 'https://console.anthropic.com/v1/oauth/token';

function read() {
  let raw;
  try {
    raw = fs.readFileSync(CRED_PATH, 'utf8');
  } catch {
    throw new Error(`Cannot read ${CRED_PATH}. Log in with \`claude\` first.`);
  }
  const json = JSON.parse(raw);
  if (!json.claudeAiOauth?.accessToken) {
    throw new Error(`${CRED_PATH} has no claude.ai OAuth token.`);
  }
  return json;
}

async function refresh(json) {
  const oauth = json.claudeAiOauth;
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'refresh_token',
      refresh_token: oauth.refreshToken,
      client_id: CLIENT_ID,
    }),
  });
  if (!res.ok) {
    throw new Error(`Claude token refresh failed (${res.status}): ${await res.text()}`
      + ' Run `claude` (without the proxy) to re-authenticate.');
  }
  const data = await res.json();
  const updated = {
    ...json,
    claudeAiOauth: {
      ...oauth,
      accessToken: data.access_token || oauth.accessToken,
      refreshToken: data.refresh_token || oauth.refreshToken,
      expiresAt: data.expires_in
        ? Date.now() + data.expires_in * 1000
        : oauth.expiresAt,
    },
  };
  fs.writeFileSync(CRED_PATH, JSON.stringify(updated, null, 2));
  return updated;
}

let cached = null;

// Returns a valid access token, refreshing within 5 minutes of expiry.
async function accessToken({ force = false } = {}) {
  if (!cached) cached = read();
  const soon = Date.now() + 5 * 60 * 1000;
  if (force || (cached.claudeAiOauth.expiresAt || 0) < soon) {
    cached = await refresh(cached);
  }
  return cached.claudeAiOauth.accessToken;
}

module.exports = { accessToken, CRED_PATH };
