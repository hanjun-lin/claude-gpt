<#
.SYNOPSIS
    Removes claude-gpt. Leaves your Claude and Codex logins untouched.
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [switch] $KeepPath
)

$ErrorActionPreference = 'Stop'
$ProxyDir = Join-Path $env:USERPROFILE '.claude\gpt-proxy'

Write-Host ''
Write-Host 'Uninstalling claude-gpt...'

# Stop a running proxy first so files aren't locked.
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like '*gpt-proxy*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
        Write-Host "  stopped proxy (pid $($_.ProcessId))"
    }

foreach ($f in @('claude-gpt.ps1', 'claude-gpt.cmd')) {
    $p = Join-Path $InstallDir $f
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "  removed $p" }
}

if (Test-Path $ProxyDir) {
    Remove-Item $ProxyDir -Recurse -Force
    Write-Host "  removed $ProxyDir"
}

if (-not $KeepPath) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath) {
        $kept = $userPath -split ';' |
                Where-Object { $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\') }
        [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
        Write-Host "  cleaned user PATH"
    }
}

Write-Host ''
Write-Host 'Done. Your ~\.codex and ~\.claude logins were not touched.'
Write-Host ''
