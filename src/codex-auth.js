// Reads (and refreshes) the ChatGPT-subscription credentials that the Codex
// CLI stores in ~/.codex/auth.json.

const fs = require('fs');
const os = require('os');
const path = require('path');

const AUTH_PATH = process.env.CODEX_AUTH_PATH || path.join(os.homedir(), '.codex', 'auth.json');
const CLIENT_ID = process.env.CODEX_CLIENT_ID || 'app_EMoamEEZ73f0CkXaXp7hrann';
const TOKEN_URL = 'https://auth.openai.com/oauth/token';

function read() {
  let raw;
  try {
    raw = fs.readFileSync(AUTH_PATH, 'utf8');
  } catch {
    throw new Error(`Cannot read ${AUTH_PATH}. Run \`codex login\` first.`);
  }
  const json = JSON.parse(raw);
  if (json.auth_mode !== 'chatgpt' || !json.tokens?.access_token) {
    throw new Error(`${AUTH_PATH} is not a ChatGPT-subscription login (auth_mode=${json.auth_mode}).`);
  }
  return json;
}

// account_id is stored alongside the tokens, but fall back to the id_token
// claim if an older auth.json omits it.
function accountIdFrom(tokens) {
  if (tokens.account_id) return tokens.account_id;
  const jwt = tokens.id_token || tokens.access_token;
  try {
    const claims = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
    return claims['https://api.openai.com/auth']?.chatgpt_account_id || null;
  } catch {
    return null;
  }
}

function expiresAt(accessToken) {
  try {
    const claims = JSON.parse(Buffer.from(accessToken.split('.')[1], 'base64url').toString('utf8'));
    return typeof claims.exp === 'number' ? claims.exp * 1000 : 0;
  } catch {
    return 0;
  }
}

async function refresh(json) {
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_id: CLIENT_ID,
      grant_type: 'refresh_token',
      refresh_token: json.tokens.refresh_token,
      scope: 'openid profile email',
    }),
  });
  if (!res.ok) {
    throw new Error(`Token refresh failed (${res.status}): ${await res.text()}. Run \`codex login\` again.`);
  }
  const data = await res.json();
  const updated = {
    ...json,
    last_refresh: new Date().toISOString(),
    tokens: {
      ...json.tokens,
      access_token: data.access_token || json.tokens.access_token,
      refresh_token: data.refresh_token || json.tokens.refresh_token,
      id_token: data.id_token || json.tokens.id_token,
    },
  };
  // Write back so the official CLI and this proxy stay in sync.
  fs.writeFileSync(AUTH_PATH, JSON.stringify(updated, null, 2));
  return updated;
}

let cached = null;

// Returns { accessToken, accountId }, refreshing when within 5 min of expiry.
async function credentials({ force = false } = {}) {
  if (!cached) cached = read();
  const soon = Date.now() + 5 * 60 * 1000;
  const exp = expiresAt(cached.tokens.access_token);
  if (force || (exp && exp < soon)) {
    cached = await refresh(cached);
  }
  return {
    accessToken: cached.tokens.access_token,
    accountId: accountIdFrom(cached.tokens),
  };
}

module.exports = { credentials, AUTH_PATH };
