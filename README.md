# claude-gpt

Keep working in **Claude Code** after you hit your 5-hour or weekly limit — by routing it to **GPT models through your ChatGPT subscription**.

Switch between Claude and GPT live, mid-session, with `/model`. No restart, same tools, same flags.

```
/model gpt        →  gpt-5.5        (ChatGPT subscription)
/model gpt-mini   →  gpt-5.4-mini
/model opus       →  Claude Opus    (your claude.ai plan)
```

---

## ⚠️ Read this first

This authenticates to OpenAI's Codex backend **as if it were the Codex CLI** (it sends Codex's `originator` and public client ID from a client that isn't Codex).

- **This is against OpenAI's Terms of Service.** Your account could be suspended.
- `chatgpt.com/backend-api/codex` is an internal endpoint with no stability guarantee. It can change or break without notice.
- You are using your own paid subscription — but the risk is yours.

If you'd rather stay fully within terms, set `GPT_PROXY_BACKEND=openai` and supply an `OPENAI_API_KEY` to bill per-token through the official API instead. Everything else works the same.

---

## How it works

Claude Code speaks the Anthropic Messages API and lets you point it anywhere via `ANTHROPIC_BASE_URL`. This project puts a small local proxy at that address and **routes every request by the model name it asks for**:

```
                       ┌──────────────────────────────────────┐
                       │   claude-gpt proxy  (127.0.0.1:8787) │
 Claude Code  ──────►  │                                      │
 ANTHROPIC_BASE_URL    │   model is gpt-* ?                   │
                       │      yes ──► Codex Responses API ────┼──►  chatgpt.com
                       │              (ChatGPT subscription)  │
                       │      no  ──► forward unchanged ──────┼──►  api.anthropic.com
                       │              (your claude.ai OAuth)  │
                       └──────────────────────────────────────┘
```

Because routing happens **per request**, `/model` switches providers instantly without restarting the session.

GPT requests are translated between the two API shapes — messages, system prompts, tool definitions, tool calls, tool results, images, and streaming events all map across. Claude requests are forwarded byte-for-byte and are unaffected.

---

## Requirements

| | |
|---|---|
| **Node.js** | v18 or newer (needs global `fetch`) |
| **Claude Code** | [claude.com/claude-code](https://claude.com/claude-code) |
| **Codex CLI** | logged in with **Sign in with ChatGPT** — creates `~/.codex/auth.json` |
| **ChatGPT plan** | Plus / Pro / Business (whichever grants Codex access) |
| **OS** | Windows 10 / 11 |

---

## Install

```powershell
git clone https://github.com/hanjun-lin/claude-gpt.git
cd claude-gpt
.\install.ps1
```

If PowerShell blocks the script:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer copies the proxy to `~\.claude\gpt-proxy`, the launcher to `~\.local\bin`, adds that directory to your user PATH, and reports what's missing. It's safe to re-run to upgrade.

Then open a **new terminal** and:

```powershell
claude-gpt
```

### First-time setup

If you've never logged in to Codex:

```powershell
npm install -g @openai/codex
codex login          # choose "Sign in with ChatGPT"
```

To be able to switch *back* to Claude models, run `claude` once normally so it stores your claude.ai login.

---

## Usage

```powershell
claude-gpt                     # start on GPT
claude-gpt --model opus        # start on Claude
claude-gpt -p "fix this bug"   # any normal claude flag passes through
```

Inside a session:

| Command | Goes to |
|---|---|
| `/model gpt` | `gpt-5.5` via ChatGPT subscription |
| `/model gpt-5.5` | same, explicit |
| `/model gpt-mini` | `gpt-5.4-mini` |
| `/model opus` | Claude Opus, your claude.ai plan |
| `/model sonnet` | Claude Sonnet |

> **Note:** the `/model` picker menu only lists Anthropic's built-in models — the GPT names aren't in that list. Type `/model gpt` as a command instead of selecting from the menu.

---

## Configuration

Set these before launching (the proxy reads them at startup):

| Variable | Default | Meaning |
|---|---|---|
| `GPT_PROXY_BACKEND` | `codex` | `codex` = ChatGPT subscription, `openai` = API key |
| `GPT_PROXY_MODEL` | `gpt-5.5` | model for the main slot |
| `GPT_PROXY_SMALL_MODEL` | `gpt-5.4-mini` | model for `gpt-mini` |
| `GPT_PROXY_REASONING` | `medium` | `low` / `medium` / `high` |
| `GPT_PROXY_PORT` | `8787` | proxy port |
| `GPT_PROXY_DEBUG` | – | `1` to log routing and payload detail |
| `OPENAI_API_KEY` | – | required only for `GPT_PROXY_BACKEND=openai` |

Example:

```powershell
$env:GPT_PROXY_REASONING = 'high'
# restart the proxy so it picks this up:
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*gpt-proxy*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
claude-gpt
```

### Which models can I use?

ChatGPT-account plans only allow a **subset** of models on the Codex endpoint. At time of writing that's `gpt-5.5` and `gpt-5.4-mini`; everything else returns *"not supported when using Codex with a ChatGPT account."*

Re-check for your own plan at any time:

```powershell
node ~\.claude\gpt-proxy\probe-models.js
```

```
OK    gpt-5.5
400   gpt-5.5-codex  {"detail":"The 'gpt-5.5-codex' model is not supported..."}
OK    gpt-5.4-mini
```

---

## Project layout

```
claude-gpt/
├── bin/
│   ├── claude-gpt.ps1          launcher (starts proxy, sets env, runs claude)
│   └── claude-gpt.cmd          cmd.exe shim
├── src/
│   ├── server.js               HTTP layer + model-based routing
│   ├── codex-auth.js           reads/refreshes ~/.codex/auth.json
│   ├── codex-backend.js        Anthropic → Codex Responses translation
│   ├── claude-auth.js          reads/refreshes ~/.claude/.credentials.json
│   ├── anthropic-passthrough.js  forwards Claude models upstream
│   ├── openai-backend.js       Anthropic → Chat Completions (API-key mode)
│   └── anthropic-stream.js     shared SSE writer + reader
├── tools/
│   └── probe-models.js         discover which models your plan allows
├── docs/
│   └── TROUBLESHOOTING.md
├── install.ps1
└── uninstall.ps1
```

---

## Troubleshooting

Enable logging first — it answers most questions:

```powershell
$env:GPT_PROXY_DEBUG = '1'
Get-Content ~\.claude\gpt-proxy\proxy.log -Wait
```

| Symptom | Cause / fix |
|---|---|
| `model is not supported when using Codex with a ChatGPT account` | Your plan doesn't allow that slug. Run `probe-models.js`. |
| `429 rate_limit_error` on a Claude model | You're at your Claude limit — that's the whole point. `/model gpt`. |
| `Cannot read ~/.codex/auth.json` | Run `codex login` and pick *Sign in with ChatGPT*. |
| `Claude token refresh failed` | Run plain `claude` (not `claude-gpt`) once to re-authenticate. |
| `claude-gpt` not found | Open a new terminal, or re-run `install.ps1`. |
| Connectors warning on startup | Expected. `ANTHROPIC_AUTH_TOKEN` is set, so claude.ai connectors are disabled. Harmless. |
| Connectors warning in a *plain* `claude` session | The token is persisted somewhere outside this project. `.\uninstall.ps1 -AuditOnly` names the file or variable; drop `-AuditOnly` to clear what it can. |

More detail in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Uninstall

```powershell
.\uninstall.ps1
```

Two jobs: it removes claude-gpt, and it clears the Anthropic auth sources that keep claude.ai connectors switched off.

### 1. Removing claude-gpt

Stops the running proxy, deletes `~\.claude\gpt-proxy` and the launcher in `~\.local\bin`, and takes that directory back off your user PATH.

### 2. Clearing the auth sources

While claude-gpt is running, Claude Code says:

> claude.ai connectors are disabled because `ANTHROPIC_API_KEY` or another auth source is set and takes precedence over your claude.ai login

That's expected — the launcher sets `ANTHROPIC_AUTH_TOKEN` so Claude Code talks to the proxy instead of Anthropic. It sets it **for one process only**, so it should disappear the moment you close that terminal. If the banner survives a brand-new terminal, the value is persisted somewhere, and Claude Code will go on preferring it over your claude.ai login.

The uninstaller audits every place that can hold one:

| Where it looks | What it does |
|---|---|
| `ANTHROPIC_*`, `CLAUDE_CODE_*` and `GPT_PROXY_*` in the Process, User and Machine environment | removes them — Machine scope needs an elevated shell |
| `env` blocks and `apiKeyHelper` / `awsAuthRefresh` in `~\.claude\settings.json`, `settings.local.json`, and the same pair under `<project>\.claude\` | removes only those keys and leaves the rest of the file untouched |
| `primaryApiKey` in `~\.claude.json` | cuts the key out |
| `~\.claude\config.json`, `%LOCALAPPDATA%\ClaudeCode`, `%APPDATA%\ClaudeCode` — written by IDE extensions and model switchers like CC-Switch, not by Claude Code | deletes them |
| `%PROGRAMDATA%\ClaudeCode\managed-settings.json` | reports it; strips it only with `-IncludeManagedSettings`, elevated |
| PowerShell profiles and `<project>\.env` | **reports only, never edits** — those are yours, and the values are masked in the output |

Then it repeats the audit and tells you what survived:

```
Auth sources currently visible to Claude Code...
  [find] ANTHROPIC_AUTH_TOKEN is set in the Process environment
  [find] env.ANTHROPIC_API_KEY in C:\Users\you\.claude\settings.json
  [find] primaryApiKey in C:\Users\you\.claude.json
  ...
Re-checking...
  [ok]   no auth source left -- claude.ai connectors will load again
```

Anything still listed after the second pass is being injected from outside Claude Code — an IDE AI extension, a model switcher, or machine policy. Close every IDE window and edit the files it names.

**Nothing is changed without a backup.** Files are copied to `~\.claude\claude-gpt-uninstall-backup\<timestamp>\` before being rewritten, and any removed environment variables are written to a `restore-env.ps1` in that same folder. That restore script holds the live values — delete it once you're happy.

### Flags

| Flag | Effect |
|---|---|
| `-AuditOnly` | Report every auth source found and change nothing. Safe to run any time. |
| `-ProjectDir <path>` | Which repo's `.claude\settings*.json` and `.env` to audit. Defaults to the current directory — point it at the repo where you actually see the banner. |
| `-ResetClaudeLogin` | Also run `claude auth logout` and delete `~\.claude\.credentials.json`. The only step that touches your login, which is why it's opt-in. |
| `-IncludeManagedSettings` | Also strip `%PROGRAMDATA%\ClaudeCode\managed-settings.json`. Needs an elevated shell, and IT policy may push it straight back. |
| `-KeepEnv` / `-KeepPath` | Leave environment variables / PATH untouched. |
| `-WhatIf` | Standard PowerShell dry run. |

Your `~\.codex` login is never touched; your `~\.claude` login only with `-ResetClaudeLogin`.

### Starting clean afterwards

The uninstaller prints these at the end. Claude Code decides about connectors when a session starts, so a session you already have open won't change its mind.

1. Close VS Code / Cursor / JetBrains, so their AI extensions can't re-inject `ANTHROPIC_*` into the terminals they spawn.
2. Open a plain PowerShell window (`Win`+`R` → `powershell`):

   ```powershell
   $env:ANTHROPIC_API_KEY = $null
   $env:ANTHROPIC_AUTH_TOKEN = $null
   $env:ANTHROPIC_BASE_URL = $null
   claude auth login
   ```

3. Confirm with `claude auth status`, then `/status` inside a session — your organization and its connectors should be back.

> `/logout` and `/login` only work *inside* a session. From the command line it's `claude auth logout` / `claude auth login`.

---

## Security notes

- The proxy binds to **127.0.0.1 only**. Anything that can reach it can spend your subscription — don't expose it.
- It reads and rewrites the token files in `~/.codex/auth.json` and `~/.claude/.credentials.json`. Once `ANTHROPIC_BASE_URL` is set, Claude Code stops refreshing its own token, so the proxy takes that over.
- `.gitignore` excludes `auth.json`, `.credentials.json`, and `*.log`. **Never commit those** — they contain live OAuth tokens.

---

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Anthropic or OpenAI.
