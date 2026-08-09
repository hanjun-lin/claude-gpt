<#
.SYNOPSIS
    Installs claude-gpt: run Claude Code against GPT models via your ChatGPT
    subscription, with live /model switching.

.DESCRIPTION
    Copies the proxy into %USERPROFILE%\.claude\gpt-proxy, the launcher into
    %USERPROFILE%\.local\bin, and puts that directory on your user PATH.
    Safe to re-run; it overwrites in place to upgrade.

.PARAMETER InstallDir
    Where the launcher goes. Default %USERPROFILE%\.local\bin

.PARAMETER NoPath
    Skip modifying PATH.

.EXAMPLE
    .\install.ps1
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [switch] $NoPath
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProxyDir = Join-Path $env:USERPROFILE '.claude\gpt-proxy'

function Say  ($m) { Write-Host $m }
function Ok   ($m) { Write-Host "  [ok]   $m"   -ForegroundColor Green }
function Warn ($m) { Write-Host "  [warn] $m"   -ForegroundColor Yellow }
function Fail ($m) { Write-Host "  [fail] $m"   -ForegroundColor Red }

Say ''
Say 'claude-gpt installer'
Say '===================='
Say ''

# --- prerequisites -----------------------------------------------------------
Say 'Checking prerequisites...'

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Fail 'Node.js not found. Install it from https://nodejs.org (v18 or newer), then re-run.'
    exit 1
}
$nodeMajor = [int](((& node -v) -replace '^v','') -split '\.')[0]
if ($nodeMajor -lt 18) {
    Fail "Node.js $(& node -v) is too old; v18+ is required (global fetch)."
    exit 1
}
Ok "Node.js $(& node -v)"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Ok 'Claude Code CLI found'
} else {
    Warn 'Claude Code CLI not on PATH. Install it from https://claude.com/claude-code'
}

# --- copy files --------------------------------------------------------------
Say ''
Say 'Installing...'

New-Item -ItemType Directory -Force $ProxyDir   | Out-Null
New-Item -ItemType Directory -Force $InstallDir | Out-Null

# src\ and tools\ land flat in the proxy dir; the launcher goes on PATH.
Copy-Item (Join-Path $Root 'src\*.js')   $ProxyDir   -Force
Copy-Item (Join-Path $Root 'tools\*.js') $ProxyDir   -Force
Copy-Item (Join-Path $Root 'bin\*')      $InstallDir -Force
Ok "proxy    -> $ProxyDir"
Ok "launcher -> $InstallDir"

# --- PATH --------------------------------------------------------------------
if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $machine  = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $already  = (($userPath, $machine) -join ';') -split ';' |
                Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') }

    if ($already) {
        Ok 'PATH already contains the install directory'
    } else {
        $new = if ([string]::IsNullOrWhiteSpace($userPath)) { $InstallDir }
               else { "$($userPath.TrimEnd(';'));$InstallDir" }
        [Environment]::SetEnvironmentVariable('PATH', $new, 'User')
        $env:PATH = "$env:PATH;$InstallDir"
        Ok "added to user PATH: $InstallDir"
        Warn 'Open a new terminal for PATH changes to take effect.'
    }
}

# --- credentials -------------------------------------------------------------
Say ''
Say 'Checking credentials...'

$codexAuth = Join-Path $env:USERPROFILE '.codex\auth.json'
if (Test-Path $codexAuth) {
    try {
        $mode = (Get-Content $codexAuth -Raw | ConvertFrom-Json).auth_mode
        if ($mode -eq 'chatgpt') { Ok 'ChatGPT subscription login found (~\.codex\auth.json)' }
        else { Warn "~\.codex\auth.json has auth_mode='$mode'; run 'codex login' and choose Sign in with ChatGPT." }
    } catch { Warn 'Could not parse ~\.codex\auth.json' }
} else {
    Warn 'No ~\.codex\auth.json. Install the Codex CLI and run: codex login'
    Warn 'Alternatively set GPT_PROXY_BACKEND=openai and OPENAI_API_KEY to bill an API key.'
}

$claudeCreds = Join-Path $env:USERPROFILE '.claude\.credentials.json'
if (Test-Path $claudeCreds) { Ok 'Claude Code login found' }
else { Warn 'No Claude login yet. Run `claude` once to sign in (needed to switch back to Claude models).' }

# --- done --------------------------------------------------------------------
Say ''
Say 'Done.'
Say ''
Say '  claude-gpt                 start a session (defaults to GPT)'
Say '  claude-gpt --model opus    start on Claude instead'
Say ''
Say '  Inside a session, switch live:'
Say '    /model gpt        -> gpt-5.5        (ChatGPT subscription)'
Say '    /model gpt-mini   -> gpt-5.4-mini'
Say '    /model opus       -> Claude Opus    (your claude.ai plan)'
Say ''
