// Probes which model slugs the Codex backend accepts for this ChatGPT plan.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// Resolves both from the repo (tools/ beside src/) and once installed flat.
const { credentials } = require(
  fs.existsSync(path.join(__dirname, 'codex-auth.js')) ? './codex-auth' : '../src/codex-auth',
);

const CANDIDATES = process.argv.slice(2).length ? process.argv.slice(2) : [
  'gpt-5.5', 'gpt-5.5-codex', 'gpt-5.4', 'gpt-5.4-codex', 'gpt-5.4-mini',
  'gpt-5.3-codex', 'gpt-5.3', 'gpt-5-codex', 'gpt-5', 'gpt-5-mini',
  'codex-mini-latest', 'o4-mini',
];

(async () => {
  const { accessToken, accountId } = await credentials();
  for (const model of CANDIDATES) {
    const res = await fetch('https://chatgpt.com/backend-api/codex/responses', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'text/event-stream',
        authorization: `Bearer ${accessToken}`,
        'chatgpt-account-id': accountId || '',
        'openai-beta': 'responses=experimental',
        originator: 'codex_cli_rs',
        session_id: crypto.randomUUID(),
      },
      body: JSON.stringify({
        model,
        instructions: 'You are terse.',
        input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hi' }] }],
        stream: true,
        store: false,
        reasoning: { effort: 'low' },
      }),
    });
    if (res.ok) {
      console.log(`OK    ${model}`);
      res.body.cancel();
    } else {
      const t = (await res.text()).slice(0, 160).replace(/\s+/g, ' ');
      console.log(`${res.status}   ${model}  ${t}`);
    }
  }
})().catch((e) => { console.error(e.message); process.exit(1); });
