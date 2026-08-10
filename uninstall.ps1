<#
.SYNOPSIS
    Removes claude-gpt and clears the Anthropic auth sources it leaves behind.

.DESCRIPTION
    Reverses install.ps1: stops the proxy, deletes the proxy directory and the
    launcher, and takes the install directory back off your user PATH.

    It then hunts down whatever is causing Claude Code to print

        claude.ai connectors are disabled because ANTHROPIC_API_KEY or another
        auth source is set and takes precedence over your claude.ai login

    The launcher only sets ANTHROPIC_AUTH_TOKEN for the life of one process, so
    if that banner survives a brand-new terminal, the value is persisted
    somewhere else: a User/Machine environment variable, an `env` block or
    apiKeyHelper in a settings.json, a stale primaryApiKey in ~\.claude.json, or
    an IDE / model-switcher tool (CC-Switch, JetBrains Gateway, Cursor) writing
    its own config. This script audits all of those, removes what it safely can,
    and names anything left over for you to deal with by hand.

    Everything it deletes or rewrites is backed up first to
    ~\.claude\claude-gpt-uninstall-backup\<timestamp>\

.PARAMETER InstallDir
    Where the launcher was installed. Default %USERPROFILE%\.local\bin

.PARAMETER ProjectDir
    Project whose .claude\settings*.json and .env are audited. Default: the
    current directory. Point this at the repo where you actually see the banner.

.PARAMETER KeepPath
    Leave the user PATH alone.

.PARAMETER KeepEnv
    Leave persisted environment variables alone; the audit still reports them.

.PARAMETER ResetClaudeLogin
    Also sign out (`claude auth logout`) and delete ~\.claude\.credentials.json,
    so the next `claude auth login` starts from nothing. This is the only step
    that touches your login, which is why it is off by default.

.PARAMETER IncludeManagedSettings
    Also strip auth keys out of %PROGRAMDATA%\ClaudeCode\managed-settings.json.
    Needs an elevated shell. If your IT policy pushes that file it will come
    back on the next sync.

.PARAMETER AuditOnly
    Report every auth source found and change nothing.

.EXAMPLE
    .\uninstall.ps1

.EXAMPLE
    .\uninstall.ps1 -AuditOnly -ProjectDir D:\OneDrive\git\wms-web

.EXAMPLE
    .\uninstall.ps1 -ResetClaudeLogin
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $InstallDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [string] $ProjectDir = (Get-Location).Path,
    [switch] $KeepPath,
    [switch] $KeepEnv,
    [switch] $ResetClaudeLogin,
    [switch] $IncludeManagedSettings,
    [switch] $AuditOnly
)

$ErrorActionPreference = 'Stop'

$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$ProxyDir  = Join-Path $ClaudeDir 'gpt-proxy'
$ClaudeCfg = Join-Path $env:USERPROFILE '.claude.json'
$ManagedSettings = Join-Path $env:ProgramData 'ClaudeCode\managed-settings.json'
$BackupDir = Join-Path $ClaudeDir ('claude-gpt-uninstall-backup\{0:yyyyMMdd-HHmmss}' -f (Get-Date))

function Say  ($m) { Write-Host $m }
function Ok   ($m) { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Hit  ($m) { Write-Host "  [find] $m" -ForegroundColor Cyan }
function Info ($m) { Write-Host "  [--]   $m" -ForegroundColor DarkGray }

# Any of these makes Claude Code prefer them over your claude.ai OAuth login,
# which is exactly what disables connectors.
$AuthVars = @(
    'ANTHROPIC_API_KEY'
    'ANTHROPIC_AUTH_TOKEN'
    'ANTHROPIC_BASE_URL'
    'ANTHROPIC_CUSTOM_HEADERS'
    'ANTHROPIC_BEDROCK_BASE_URL'
    'ANTHROPIC_VERTEX_BASE_URL'
    'AWS_BEARER_TOKEN_BEDROCK'
    'CLAUDE_CODE_USE_BEDROCK'
    'CLAUDE_CODE_USE_VERTEX'
    'CLAUDE_CODE_SKIP_BEDROCK_AUTH'
    'CLAUDE_CODE_SKIP_VERTEX_AUTH'
)

# Set by the launcher. Harmless to auth on their own, but ours to clean up.
$ProxyVars = @(
    'ANTHROPIC_MODEL'
    'ANTHROPIC_SMALL_FAST_MODEL'
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
    'GPT_PROXY_BACKEND'
    'GPT_PROXY_DEBUG'
    'GPT_PROXY_MODEL'
    'GPT_PROXY_PORT'
    'GPT_PROXY_REASONING'
    'GPT_PROXY_SMALL_MODEL'
)

$AllVars = $AuthVars + $ProxyVars

# Settings keys that hand Claude Code a credential without an env var.
$AuthKeys = @('apiKeyHelper', 'awsAuthRefresh', 'awsCredentialExport')

$SettingsFiles = @(
    (Join-Path $ClaudeDir 'settings.json')
    (Join-Path $ClaudeDir 'settings.local.json')
    (Join-Path $ProjectDir '.claude\settings.json')
    (Join-Path $ProjectDir '.claude\settings.local.json')
)

# Written by IDE extensions and model-switcher tools rather than Claude Code.
$ThirdPartyPaths = @(
    (Join-Path $ClaudeDir 'config.json')
    (Join-Path $env:LOCALAPPDATA 'ClaudeCode')
    (Join-Path $env:APPDATA 'ClaudeCode')
)

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# One gate for every destructive step, so -AuditOnly and -WhatIf both work.
function Should ($target, $action) {
    if ($AuditOnly) { Info "would $action -> $target"; return $false }
    return $PSCmdlet.ShouldProcess($target, $action)
}

function Backup ($path) {
    if (-not (Test-Path $path)) { return }
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Force $BackupDir | Out-Null }
    $dest = Join-Path $BackupDir (Split-Path $path -Leaf)
    $n = 1
    while (Test-Path $dest) { $dest = "$dest.$n"; $n++ }
    Copy-Item $path $dest -Recurse -Force
}

# Node's JSON.parse rejects a BOM, and Set-Content -Encoding utf8 writes one on
# Windows PowerShell, so write these files by hand.
function Write-Utf8NoBom ($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------
function Get-AuthSources {
    $found = @()

    foreach ($scope in 'Process', 'User', 'Machine') {
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($name in $AuthVars) {
            if ($vars.Contains($name)) {
                $found += "$name is set in the $scope environment"
            }
        }
    }

    foreach ($f in ($SettingsFiles + $ManagedSettings)) {
        if (-not (Test-Path $f)) { continue }
        try { $json = Get-Content $f -Raw | ConvertFrom-Json }
        catch { $found += "$f is not valid JSON, so it could not be checked"; continue }

        foreach ($k in $AuthKeys) {
            if ($json.PSObject.Properties.Name -contains $k) { $found += "$k in $f" }
        }
        if ($json.env) {
            foreach ($name in $AuthVars) {
                if ($json.env.PSObject.Properties.Name -contains $name) { $found += "env.$name in $f" }
            }
        }
    }

    if (Test-Path $ClaudeCfg) {
        if ((Get-Content $ClaudeCfg -Raw) -match '"primaryApiKey"\s*:\s*"') {
            $found += "primaryApiKey in $ClaudeCfg"
        }
    }

    foreach ($p in $ThirdPartyPaths) {
        if (Test-Path $p) { $found += "third-party config present: $p" }
    }

    # Shell profiles and .env files are the usual "invisible injector".
    $scripts = @()
    if ($PROFILE) {
        $scripts += $PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost,
                    $PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost
    }
    $scripts += (Join-Path $ProjectDir '.env')
    foreach ($s in ($scripts | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path $s)) { continue }
        $hits = Select-String -Path $s -Pattern ($AuthVars -join '|') -ErrorAction SilentlyContinue
        foreach ($h in $hits) {
            # Mask the value; these lines hold live keys.
            $found += ("{0}:{1}  {2}" -f $s, $h.LineNumber, ($h.Line.Trim() -replace '=.*', '= ...'))
        }
    }

    return $found
}

# ---------------------------------------------------------------------------
# cleanup steps
# ---------------------------------------------------------------------------
function Clear-AuthEnv {
    $removed = @()
    $admin   = Test-Admin

    foreach ($scope in 'User', 'Machine') {
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($name in $AllVars) {
            if (-not $vars.Contains($name)) { continue }
            if ($scope -eq 'Machine' -and -not $admin) {
                Warn "$name is set machine-wide; re-run this script as Administrator to remove it"
                continue
            }
            if (-not (Should "$scope environment" "remove $name")) { continue }
            $removed += [pscustomobject]@{ Scope = $scope; Name = $name; Value = $vars[$name] }
            [Environment]::SetEnvironmentVariable($name, $null, $scope)
            Ok "removed $name from the $scope environment"
        }
    }

    # This shell too, so you do not have to open a new one to test.
    foreach ($name in $AllVars) {
        if (-not (Test-Path "Env:\$name")) { continue }
        if (-not (Should 'this process' "clear $name")) { continue }
        Remove-Item "Env:\$name" -Force
        Info "cleared $name in this process"
    }

    if ($removed.Count -eq 0) { return }

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Force $BackupDir | Out-Null }
    $restore = Join-Path $BackupDir 'restore-env.ps1'
    $lines = foreach ($r in $removed) {
        "[Environment]::SetEnvironmentVariable('{0}', '{1}', '{2}')" -f `
            $r.Name, ($r.Value -replace "'", "''"), $r.Scope
    }
    Write-Utf8NoBom $restore (($lines -join "`r`n") + "`r`n")
    Warn "the removed values were saved to $restore -- it contains live keys, delete it once you are happy"
}

function Clear-SettingsAuth ($path) {
    if (-not (Test-Path $path)) { return }
    try { $json = Get-Content $path -Raw | ConvertFrom-Json }
    catch { Warn "skipped $path (not valid JSON) -- fix or delete it by hand"; return }

    $changed = @()
    foreach ($k in $AuthKeys) {
        if ($json.PSObject.Properties.Name -contains $k) {
            $json.PSObject.Properties.Remove($k); $changed += $k
        }
    }
    if ($json.env) {
        foreach ($name in $AllVars) {
            if ($json.env.PSObject.Properties.Name -contains $name) {
                $json.env.PSObject.Properties.Remove($name); $changed += "env.$name"
            }
        }
        # Leave unrelated entries alone; only drop env if we emptied it.
        if (@($json.env.PSObject.Properties).Count -eq 0) {
            $json.PSObject.Properties.Remove('env'); $changed += 'the now-empty env block'
        }
    }

    if ($changed.Count -eq 0) { return }
    if (-not (Should $path "remove $($changed -join ', ')")) { return }

    Backup $path
    Write-Utf8NoBom $path ($json | ConvertTo-Json -Depth 32)
    Ok "$path -- removed $($changed -join ', ')"
}

function Clear-PrimaryApiKey {
    if (-not (Test-Path $ClaudeCfg)) { return }
    $raw = Get-Content $ClaudeCfg -Raw
    if ($raw -notmatch '"primaryApiKey"\s*:') { return }
    if (-not (Should $ClaudeCfg 'remove primaryApiKey')) { return }

    # ~\.claude.json holds per-project history and can carry duplicate keys that
    # ConvertFrom-Json refuses, so cut the one key out textually instead.
    $value = '(?:"(?:[^"\\]|\\.)*"|null)'
    $new   = $raw
    foreach ($p in @(",\s*`"primaryApiKey`"\s*:\s*$value",
                     "`"primaryApiKey`"\s*:\s*$value\s*,",
                     "`"primaryApiKey`"\s*:\s*$value")) {
        $re = New-Object System.Text.RegularExpressions.Regex $p
        if ($re.IsMatch($new)) { $new = $re.Replace($new, '', 1); break }
    }

    if ($new -match ',\s*,' -or $new -match '\{\s*,' -or $new -match ',\s*\}') {
        Warn "left $ClaudeCfg alone -- the edit did not come out clean, remove primaryApiKey by hand"
        return
    }

    Backup $ClaudeCfg
    Write-Utf8NoBom $ClaudeCfg $new
    Ok "$ClaudeCfg -- removed primaryApiKey"
}

function Remove-ThirdParty ($path) {
    if (-not (Test-Path $path)) { Info "not present: $path"; return }
    if (-not (Should $path 'remove')) { return }
    Backup $path
    Remove-Item $path -Recurse -Force
    Ok "removed $path"
}

# ---------------------------------------------------------------------------
Say ''
Say 'claude-gpt uninstaller'
Say '======================'
if ($AuditOnly) { Warn 'audit only -- nothing will be changed' }

Say ''
Say 'Auth sources currently visible to Claude Code...'
$before = Get-AuthSources
if ($before) { $before | ForEach-Object { Hit $_ } } else { Ok 'none -- connectors should already work' }

# --- the proxy itself --------------------------------------------------------
Say ''
Say 'Removing claude-gpt...'
$touched = $false

Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like '*gpt-proxy*' } |
    ForEach-Object {
        if (Should "pid $($_.ProcessId)" 'stop the running proxy') {
            Stop-Process -Id $_.ProcessId -Force
            Ok "stopped proxy (pid $($_.ProcessId))"
            $touched = $true
        }
    }

foreach ($f in @('claude-gpt.ps1', 'claude-gpt.cmd')) {
    $p = Join-Path $InstallDir $f
    if (-not (Test-Path $p)) { continue }
    if (Should $p 'remove') { Remove-Item $p -Force; Ok "removed $p"; $touched = $true }
}

if (Test-Path $ProxyDir) {
    if (Should $ProxyDir 'remove') {
        Remove-Item $ProxyDir -Recurse -Force; Ok "removed $ProxyDir"; $touched = $true
    }
}

if (-not $touched) { Info 'claude-gpt was not installed here' }

if (-not $KeepPath) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -and (Should 'user PATH' "remove $InstallDir")) {
        $kept = $userPath -split ';' |
                Where-Object { $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\') }
        [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
        Ok 'cleaned user PATH'
    }
}

# --- the auth sources --------------------------------------------------------
Say ''
Say 'Clearing persisted auth sources...'

if ($KeepEnv) { Info 'skipping environment variables (-KeepEnv)' } else { Clear-AuthEnv }

foreach ($f in $SettingsFiles) { Clear-SettingsAuth $f }

if (Test-Path $ManagedSettings) {
    if (-not $IncludeManagedSettings) {
        Warn "$ManagedSettings exists -- re-run with -IncludeManagedSettings (elevated) to strip it"
    } elseif (-not (Test-Admin)) {
        Warn "$ManagedSettings needs an elevated shell to edit"
    } else {
        Clear-SettingsAuth $ManagedSettings
        Warn 'managed settings are usually pushed by IT policy and may come back on the next sync'
    }
}

Clear-PrimaryApiKey
foreach ($p in $ThirdPartyPaths) { Remove-ThirdParty $p }

# --- the login itself --------------------------------------------------------
if ($ResetClaudeLogin) {
    Say ''
    Say 'Resetting the Claude Code login...'
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        # `claude /logout` does not work: /logout is a slash command inside a
        # session. The CLI spells it `claude auth logout`.
        if (Should 'Claude Code' 'run claude auth logout') { & claude auth logout }
    } else {
        Warn 'claude is not on PATH; skipping claude auth logout'
    }
    $creds = Join-Path $ClaudeDir '.credentials.json'
    if (Test-Path $creds) {
        if (Should $creds 'remove') { Backup $creds; Remove-Item $creds -Force; Ok "removed $creds" }
    } else {
        Info 'no ~\.claude\.credentials.json left to remove'
    }
}

# --- what is left ------------------------------------------------------------
Say ''
Say 'Re-checking...'
$after = Get-AuthSources
if ($after) {
    $after | ForEach-Object { Hit $_ }
    Say ''
    Warn 'those survived. Shell profiles and .env files are reported but never'
    Warn 'edited -- they are yours. Anything else here is being injected from'
    Warn 'outside Claude Code: an IDE AI extension, a model-switcher such as'
    Warn 'CC-Switch, or a machine policy. Close every IDE window, then edit the'
    Warn 'files listed above by hand.'
} else {
    Ok 'no auth source left -- claude.ai connectors will load again'
}

if (Test-Path $BackupDir) { Say ''; Info "backups: $BackupDir" }

Say ''
Say 'Next steps'
Say '----------'
Say '  1. Close VS Code / Cursor / JetBrains so their AI extensions cannot'
Say '     re-inject ANTHROPIC_* into the terminals they spawn.'
Say '  2. Win+R -> powershell, for a plain shell nothing has touched:'
Say ''
Say '       $env:ANTHROPIC_API_KEY = $null'
Say '       $env:ANTHROPIC_AUTH_TOKEN = $null'
Say '       $env:ANTHROPIC_BASE_URL = $null'
Say '       claude auth login'
Say ''
Say '  3. Confirm with `claude auth status`, then `/status` inside a session.'
Say ''
if (-not $ResetClaudeLogin) {
    Info 'your ~\.codex and ~\.claude logins were not touched (-ResetClaudeLogin clears the Claude one)'
    Say ''
}
