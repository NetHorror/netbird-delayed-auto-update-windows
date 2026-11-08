# One-line installer for netbird-delayed-update (Windows).
#   irm https://github.com/NetHorror/netbird-delayed-auto-update-windows/releases/download/0.3.0/install.ps1 | iex
# Run from an elevated PowerShell. Downloads the script and SHA256SUMS of the same
# release, verifies the SHA-256 hash, copies the script to a fixed path (the
# Scheduled Task stores it), then installs the task and NetBird if it is missing.
$ErrorActionPreference = "Stop"

$ver  = if ($env:NB_DELAYED_VERSION) { $env:NB_DELAYED_VERSION } else { "0.3.0" }
$base = if ($env:NB_DELAYED_BASE)    { $env:NB_DELAYED_BASE }    else { "https://github.com/NetHorror/netbird-delayed-auto-update-windows/releases/download/$ver" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run PowerShell as Administrator, then run this command again." }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

$tmp = Join-Path $env:TEMP ("nbdu-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    Invoke-WebRequest "$base/netbird-delayed-update.ps1" -OutFile "$tmp\netbird-delayed-update.ps1" -UseBasicParsing
    Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$tmp\SHA256SUMS" -UseBasicParsing

    $line = Get-Content "$tmp\SHA256SUMS" | Where-Object { $_ -match '[\s*]netbird-delayed-update\.ps1$' } | Select-Object -First 1
    $expected = if ($line) { ($line -split '\s+')[0] } else { $null }
    $actual = (Get-FileHash "$tmp\netbird-delayed-update.ps1" -Algorithm SHA256).Hash
    if (-not $expected -or $actual -ne $expected) { throw "SHA256 check failed; nothing installed." }
    Write-Host "SHA-256 OK."

    $bin = Join-Path $env:ProgramData "NetBirdDelayedUpdate\bin"
    New-Item -ItemType Directory -Force $bin | Out-Null
    Copy-Item "$tmp\netbird-delayed-update.ps1" "$bin\netbird-delayed-update.ps1" -Force

    & powershell -NoProfile -ExecutionPolicy Bypass -File "$bin\netbird-delayed-update.ps1" -Install -InstallClient -StartWhenAvailable
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
