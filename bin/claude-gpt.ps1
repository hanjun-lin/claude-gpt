# claude-gpt — Claude Code with live /model switching between Claude and GPT.
#
#   claude-gpt                  # starts on GPT
#   claude-gpt --model opus     # starts on Claude
#
# Once inside, switch any time without restarting:
#   /model gpt          -> gpt-5.5   (ChatGPT subscription)
#   /model gpt-mini     -> gpt-5.4-mini
#   /model opus         -> Claude Opus (your claude.ai plan)
#
# Claude models are forwarded untouched to api.anthropic.com with your
# claude.ai OAuth token; GPT models go through the Codex endpoint.

$ErrorActionPreference = 'Stop'

$Port    = if ($env:GPT_PROXY_PORT) { $env:GPT_PROXY_PORT } else { '8787' }
$Proxy   = Join-Path $env:USERPROFILE '.claude\gpt-proxy\server.js'
$LogFile = Join-Path $env:USERPROFILE '.claude\gpt-proxy\proxy.log'

function Test-Proxy {
    try {
        return [bool](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).ok
    } catch { return $false }
}

if (-not (Test-Proxy)) {
    Write-Host "starting gpt-proxy on port $Port..." -ForegroundColor DarkGray
    Start-Process -FilePath 'node' -ArgumentList $Proxy `
        -WindowStyle Hidden -RedirectStandardError $LogFile
    $ok = $false
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 250
        if (Test-Proxy) { $ok = $true; break }
    }
    if (-not $ok) { Write-Error "proxy failed to start. See $LogFile" }
}

$env:ANTHROPIC_BASE_URL   = "http://127.0.0.1:$Port"
$env:ANTHROPIC_AUTH_TOKEN = 'gpt-proxy'   # replaced per-request by the proxy
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'

# Keep the background/summarisation model on GPT so it doesn't burn Claude quota.
if (-not $env:ANTHROPIC_SMALL_FAST_MODEL) { $env:ANTHROPIC_SMALL_FAST_MODEL = 'gpt-5.4-mini' }

# Default the session to GPT unless the caller asked for something specific.
if ($args -notcontains '--model') { $args = @('--model', 'gpt-5.5') + $args }

& claude @args
