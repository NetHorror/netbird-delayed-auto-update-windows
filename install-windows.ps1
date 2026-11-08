# One-line installer for netbird-delayed-update (Windows).
#   irm https://github.com/NetHorror/netbird-delayed-auto-update-windows/releases/download/0.3.0/install-windows.ps1 | iex
# Run from an elevated PowerShell. Downloads the script and SHA256SUMS of release 0.3.0,
# verifies the SHA-256 hash, copies the script to a protected folder (the Scheduled Task
# stores its path there), then installs the task and NetBird if it is missing.
# The body runs in its own scope so nothing leaks into the caller's session.
& {
    $ErrorActionPreference = "Stop"
    $ver  = "0.3.0"
    $name = "netbird-delayed-update.ps1"
    $base = "https://github.com/NetHorror/netbird-delayed-auto-update-windows/releases/download/$ver"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Run PowerShell as Administrator, then run this command again." }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

    $tmp = Join-Path $env:TEMP ("nbdu-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        Invoke-WebRequest "$base/$name" -OutFile "$tmp\$name" -UseBasicParsing
        Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$tmp\SHA256SUMS" -UseBasicParsing

        # Find the exact entry for this file name: "<64 hex>  <name>" or "<64 hex> *<name>".
        $entry = Get-Content "$tmp\SHA256SUMS" | ForEach-Object {
            if ($_ -match '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$') { [pscustomobject]@{ Hash = $matches[1]; Name = $matches[2] } }
        } | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $entry) { throw "No checksum for $name in SHA256SUMS; nothing installed." }

        $actual = (Get-FileHash "$tmp\$name" -Algorithm SHA256).Hash
        if ($actual -ne $entry.Hash) { throw "SHA256 mismatch; nothing installed." }
        Write-Host "SHA-256 OK."

        # The Scheduled Task runs this script as SYSTEM, so the folder must not be writable
        # by ordinary users. Well-known SIDs keep this correct on any Windows language.
        $bin = Join-Path $env:ProgramData "NetBirdDelayedUpdate\bin"
        New-Item -ItemType Directory -Force $bin | Out-Null
        $sysSid = "*S-1-5-18"; $admSid = "*S-1-5-32-544"; $usrSid = "*S-1-5-32-545"
        & icacls.exe $bin /setowner $admSid | Out-Null
        & icacls.exe $bin /inheritance:r /grant:r "${sysSid}:(OI)(CI)F" "${admSid}:(OI)(CI)F" "${usrSid}:(OI)(CI)RX" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict permissions on $bin; nothing installed." }
        Copy-Item "$tmp\$name" "$bin\$name" -Force

        $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        & $ps -NoProfile -ExecutionPolicy Bypass -File "$bin\$name" -Install -InstallClient -StartWhenAvailable
        if ($LASTEXITCODE -ne 0) { throw "Install failed (exit code $LASTEXITCODE)." }
        Write-Host "Done. Check: powershell -ExecutionPolicy Bypass -File `"$bin\$name`" -DelayDays 0 -MaxRandomDelaySeconds 0"
    }
    finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
