# Version: 0.3.0

<#
.SYNOPSIS
    NetBird delayed auto-update (Windows/Chocolatey).

.DESCRIPTION
    Implements staged / delayed updates for the NetBird client installed via Chocolatey.
    A new Chocolatey package version must "age" for DelayDays before it can be installed.

    Optional features:
    - GUI update via official installer feed (pkgs.netbird.io)
    - Script self-update via GitHub release assets of this repository (SHA256-verified)
    - First-time NetBird client installation (-InstallClient or interactive prompt)
    - Scheduled Task installer/uninstaller
    - Log retention

.NOTES
    Repository: https://github.com/NetHorror/netbird-delayed-auto-update-windows
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$DelayDays = 10,

    [Parameter(Mandatory = $false)]
    [int]$MaxRandomDelaySeconds = 3600,

    [Parameter(Mandatory = $false)]
    [int]$LogRetentionDays = 60,

    [Parameter(Mandatory = $false)]
    [string]$PackageName = "netbird",

    # Scheduled Task install/update
    [Parameter(Mandatory = $false)]
    [Alias("i")]
    [switch]$Install,

    # Scheduled Task uninstall
    [Parameter(Mandatory = $false)]
    [Alias("u")]
    [switch]$Uninstall,

    # When used with -Uninstall, also remove logs/state directory
    [Parameter(Mandatory = $false)]
    [switch]$RemoveState,

    # Task run time (HH:mm)
    [Parameter(Mandatory = $false)]
    [string]$DailyTime = "04:00",

    # Task name
    [Parameter(Mandatory = $false)]
    [string]$TaskName = "NetBird Delayed Choco Update",

    # Run missed execution after boot
    [Parameter(Mandatory = $false)]
    [Alias("r")]
    [switch]$StartWhenAvailable,

    # Run task as current user instead of SYSTEM
    [Parameter(Mandatory = $false)]
    [switch]$RunAsCurrentUser,

    # Install the NetBird client if it is missing, without asking
    [Parameter(Mandatory = $false)]
    [switch]$InstallClient,

    # Disable script self-update from GitHub releases
    [Parameter(Mandatory = $false)]
    [switch]$NoSelfUpdate
)

# -----------------------------
# Constants / Paths
# -----------------------------
$ScriptVersion = "0.3.0"
$BaseDir = Join-Path $env:ProgramData "NetBirdDelayedUpdate"
$StatePath = Join-Path $BaseDir "state.json"
$GuiStatePath = Join-Path $BaseDir "gui-state.json"
$LogPath = Join-Path $BaseDir ("netbird-delayed-update-{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
$ScriptRepo = "NetHorror/netbird-delayed-auto-update-windows"
$ScriptName = "netbird-delayed-update.ps1"

# -----------------------------
# Helpers
# -----------------------------
function Ensure-BaseDir {
    if (-not (Test-Path $BaseDir)) {
        New-Item -Path $BaseDir -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    Ensure-BaseDir
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Out-File -FilePath $LogPath -Encoding UTF8 -Append
    Write-Host $line
}

function Set-Tls12IfPossible {
    try {
        # Ensure TLS 1.2 is enabled for older Windows PowerShell environments.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    } catch {
        # Ignore if not available.
    }
}

function Get-GitHubHeaders {
    return @{
        "User-Agent" = "netbird-delayed-update/$ScriptVersion"
        "Accept"     = "application/vnd.github+json"
    }
}

function Invoke-WebRequestCompat {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$false)][hashtable]$Headers = $null,
        [Parameter(Mandatory=$false)][string]$OutFile = $null
    )

    $params = @{
        Uri         = $Uri
        Headers     = $Headers
        ErrorAction = "Stop"
    }

    if ($OutFile) { $params["OutFile"] = $OutFile }

    # -UseBasicParsing exists only in Windows PowerShell 5.1 and older.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $params["UseBasicParsing"] = $true
    }

    return Invoke-WebRequest @params
}

function Invoke-RestMethodCompat {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$false)][hashtable]$Headers = $null
    )

    $params = @{
        Uri         = $Uri
        Headers     = $Headers
        ErrorAction = "Stop"
    }

    # Do NOT use -UseBasicParsing here; it's not supported on PowerShell 6+.
    return Invoke-RestMethod @params
}

function Read-JsonFile {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Failed to read JSON file: $Path. Error: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Object
    )
    Ensure-BaseDir
    try {
        ($Object | ConvertTo-Json -Depth 10) | Out-File -FilePath $Path -Encoding UTF8 -Force
    } catch {
        Write-Log "Failed to write JSON file: $Path. Error: $($_.Exception.Message)" "ERROR"
    }
}

function Cleanup-OldLogs {
    if ($LogRetentionDays -le 0) { return }
    try {
        if (-not (Test-Path $BaseDir)) { return }
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -Path $BaseDir -Filter "netbird-delayed-update-*.log" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                try {
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                } catch {
                    Write-Log "Failed to remove old log file: $($_.FullName). Error: $($_.Exception.Message)" "WARN"
                }
            }
    } catch {
        Write-Log "Log retention cleanup failed: $($_.Exception.Message)" "WARN"
    }
}

function Compare-SemVer {
    param(
        [Parameter(Mandatory=$true)][string]$A,
        [Parameter(Mandatory=$true)][string]$B
    )
    try {
        $va = [version]$A
        $vb = [version]$B
        return $va.CompareTo($vb)
    } catch {
        return 0
    }
}

# -----------------------------
# Self-update (GitHub releases)
# -----------------------------
function Try-SelfUpdate {
    if ($NoSelfUpdate) {
        Write-Log "Self-update: disabled by -NoSelfUpdate." "INFO"
        return
    }
    if ([string]::IsNullOrWhiteSpace($ScriptRepo)) { return }
    if (-not $PSCommandPath) { return }

    Set-Tls12IfPossible

    try {
        $headers = Get-GitHubHeaders
        $api = "https://api.github.com/repos/$ScriptRepo/releases/latest"
        $rel = Invoke-RestMethodCompat -Uri $api -Headers $headers
        $tag = ([string]$rel.tag_name).Trim()
        if ([string]::IsNullOrWhiteSpace($tag)) { return }

        $remoteVersion = $tag -replace '^v', ''
        if ($remoteVersion -notmatch '^\d+\.\d+\.\d+$') {
            Write-Log "Self-update: latest release tag '$tag' is not a plain X.Y.Z version; skipping." "WARN"
            return
        }
        $cmp = Compare-SemVer -A $remoteVersion -B $ScriptVersion
        if ($cmp -le 0) {
            Write-Log "Self-update: already on latest version ($ScriptVersion)." "INFO"
            return
        }

        Write-Log "Self-update: remote version is newer ($remoteVersion > $ScriptVersion). Attempting update..." "INFO"

        # Only release assets are used: the script itself and SHA256SUMS.
        $scriptAsset = @($rel.assets) | Where-Object { $_ -and $_.name -eq $ScriptName } | Select-Object -First 1
        $sumsAsset   = @($rel.assets) | Where-Object { $_ -and $_.name -eq "SHA256SUMS" } | Select-Object -First 1
        if (-not $scriptAsset -or -not $scriptAsset.browser_download_url -or
            -not $sumsAsset -or -not $sumsAsset.browser_download_url) {
            Write-Log "Self-update: release $tag has no '$ScriptName' and/or 'SHA256SUMS' asset; nothing changed." "WARN"
            return
        }

        # Temp files MUST live in the same directory as the target so the
        # final Move-Item is an atomic rename (using $env:TEMP can land on a
        # different volume, turning the move into a non-atomic copy+delete
        # that can leave a truncated script behind if interrupted).
        $target = $PSCommandPath
        $scriptDir = Split-Path -Parent $target
        $guid = [Guid]::NewGuid().ToString("N")
        $tmpScript = Join-Path $scriptDir (".{0}.new-{1}.tmp" -f $ScriptName, $guid)
        $tmpSums   = Join-Path $scriptDir (".SHA256SUMS.new-{0}.tmp" -f $guid)
        $dlHeaders = @{ "User-Agent" = "netbird-delayed-update/$ScriptVersion" }

        try {
            Invoke-WebRequestCompat -Uri ([string]$scriptAsset.browser_download_url) -Headers $dlHeaders -OutFile $tmpScript | Out-Null
            Invoke-WebRequestCompat -Uri ([string]$sumsAsset.browser_download_url) -Headers $dlHeaders -OutFile $tmpSums | Out-Null

            # Find the expected hash for the exact file name in SHA256SUMS
            # (format: "<hex>  <name>" or "<hex> *<name>").
            $expected = $null
            foreach ($line in (Get-Content -Path $tmpSums -ErrorAction Stop)) {
                $m = [regex]::Match([string]$line, '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$')
                if ($m.Success -and $m.Groups[2].Value -ceq $ScriptName) {
                    $expected = $m.Groups[1].Value
                    break
                }
            }
            if (-not $expected) {
                Write-Log "Self-update: SHA256SUMS has no entry for '$ScriptName'; nothing changed." "ERROR"
                return
            }

            $actual = (Get-FileHash -Path $tmpScript -Algorithm SHA256 -ErrorAction Stop).Hash
            if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "Self-update: SHA256 mismatch for '$ScriptName' (expected $expected, got $actual); nothing changed." "ERROR"
                return
            }

            # The downloaded file must declare the version from the release tag.
            $downloadedContent = Get-Content -Path $tmpScript -Raw -ErrorAction Stop
            if ($downloadedContent -notmatch [regex]::Escape("`$ScriptVersion = `"$remoteVersion`"")) {
                Write-Log "Self-update: downloaded file does not declare `$ScriptVersion = `"$remoteVersion`"; nothing changed." "ERROR"
                return
            }

            # Keep the target's DACL: copy it onto the new file before the rename.
            $acl = Get-Acl -Path $target -ErrorAction Stop
            $newAcl = New-Object System.Security.AccessControl.FileSecurity
            $newAcl.SetSecurityDescriptorSddlForm($acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access), [System.Security.AccessControl.AccessControlSections]::Access)
            Set-Acl -Path $tmpScript -AclObject $newAcl -ErrorAction Stop

            $backup = "{0}.bak-{1}" -f $target, (Get-Date -Format "yyyyMMdd-HHmmss")
            Copy-Item -Path $target -Destination $backup -Force -ErrorAction Stop

            Move-Item -Path $tmpScript -Destination $target -Force -ErrorAction Stop
            Write-Log "Self-update: script updated to $remoteVersion from release asset (SHA256 verified). Backup: $backup. The new version is used on the next run." "INFO"
        } finally {
            Remove-Item -Path $tmpScript -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tmpSums -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Self-update failed: $($_.Exception.Message)" "WARN"
    }
}

# -----------------------------
# Chocolatey helpers
# -----------------------------
function Get-ChocoLocalVersion {
    param([string]$Pkg)
    try {
        $out = & choco list $Pkg --localonly --exact --limit-output 2>$null
        if (-not $out) { return $null }
        $parts = $out.Trim().Split("|")
        if ($parts.Count -ge 2) { return $parts[1].Trim() }
        return $null
    } catch {
        return $null
    }
}

function Get-ChocoRemoteVersion {
    param([string]$Pkg)
    try {
        $out = & choco search $Pkg --exact --limit-output 2>$null
        if (-not $out) { return $null }
        $parts = $out.Trim().Split("|")
        if ($parts.Count -ge 2) { return $parts[1].Trim() }
        return $null
    } catch {
        return $null
    }
}

function Upgrade-ChocoPackage {
    param(
        [string]$Pkg,
        # The matured version to install. Without it choco installs whatever is
        # newest right now, which can skip the delay entirely.
        [Parameter(Mandatory=$true)][string]$Version
    )
    try {
        Write-Log "Upgrading Chocolatey package '$Pkg' to $Version..." "INFO"
        & choco upgrade $Pkg --version $Version -y --no-progress
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Write-Log "Chocolatey upgrade failed with exit code $code." "ERROR"
            return $false
        }
        return $true
    } catch {
        Write-Log "Chocolatey upgrade failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -----------------------------
# Service handling
# -----------------------------
function Find-NetBirdService {
    # Try common names first.
    $candidates = @("Netbird", "NetBird", "netbird")
    foreach ($n in $candidates) {
        try {
            $svc = Get-Service -Name $n -ErrorAction Stop
            if ($svc) { return $svc }
        } catch { }
    }

    # Fallback: search by display name / name
    try {
        $svc = Get-Service -ErrorAction Stop | Where-Object {
            $_.DisplayName -match "NetBird" -or $_.Name -match "NetBird" -or $_.Name -match "netbird"
        } | Select-Object -First 1
        return $svc
    } catch {
        return $null
    }
}

function Restart-NetBirdServiceIfPresent {
    try {
        $svc = Find-NetBirdService
        if (-not $svc) {
            Write-Log "NetBird service not found; skipping service restart." "WARN"
            return
        }

        if ($svc.Status -eq "Running") {
            Write-Log "Stopping service '$($svc.Name)'..." "INFO"
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
        Write-Log "Starting service '$($svc.Name)'..." "INFO"
        Start-Service -Name $svc.Name -ErrorAction Stop
    } catch {
        Write-Log "Service restart failed: $($_.Exception.Message)" "WARN"
    }
}

# -----------------------------
# Client detection / first install
# -----------------------------
function Test-ChocoAvailable {
    return [bool](Get-Command choco -ErrorAction SilentlyContinue)
}

function Get-NetBirdExePath {
    $pf = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($pf)) { $pf = $env:ProgramFiles }
    return Join-Path $pf "NetBird\netbird.exe"
}

function Test-NetBirdClientPresent {
    if (Find-NetBirdService) { return $true }
    if (Test-Path -LiteralPath (Get-NetBirdExePath)) { return $true }
    if (Get-ChocoLocalVersion -Pkg $PackageName) { return $true }
    return $false
}

function Test-InteractiveSession {
    if (-not [Environment]::UserInteractive) { return $false }
    try {
        if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { return $false }
    } catch { }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    } catch { }
    # powershell.exe / pwsh started with -NonInteractive cannot prompt.
    if ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^[-/]noni' }) { return $false }
    return $true
}

function Install-NetBirdClient {
    Write-Log "Client install: first installation always installs the CURRENT latest NetBird version (DelayDays applies only to later updates)." "INFO"

    if (Test-ChocoAvailable) {
        try {
            Write-Log "Client install: installing Chocolatey package '$PackageName'..." "INFO"
            & choco install $PackageName -y --no-progress
            $code = $LASTEXITCODE
            if ($code -ne 0) {
                Write-Log "Client install: choco install failed with exit code $code." "ERROR"
                return $false
            }
            Write-Log "Client install: installed via Chocolatey ($(Get-ChocoLocalVersion -Pkg $PackageName))." "INFO"
            return $true
        } catch {
            Write-Log "Client install: choco install failed: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }

    Write-Log "Client install: Chocolatey not found; using the official installer. Delayed daemon updates will NOT work for this installation (they are done only via Chocolatey)." "WARN"

    Set-Tls12IfPossible
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("netbird-install-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
    try {
        Invoke-WebRequestCompat -Uri "https://pkgs.netbird.io/windows/x64" -Headers $null -OutFile $tmp | Out-Null

        $sig = Get-AuthenticodeSignature -FilePath $tmp
        $signerOk = $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -like "*CN=NetBird GmbH*")
        if ($sig.Status -ne "Valid" -or -not $signerOk) {
            Write-Log "Client install: installer signature check failed (status: $($sig.Status)); not installing." "ERROR"
            return $false
        }

        $p = Start-Process -FilePath $tmp -ArgumentList "/S" -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Write-Log "Client install: installer returned exit code $($p.ExitCode)." "ERROR"
            return $false
        }
        Write-Log "Client install: NetBird installed via the official installer." "INFO"
        return $true
    } catch {
        Write-Log "Client install failed: $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Returns $true when the client is present (or was just installed).
function Confirm-NetBirdClient {
    if (Test-NetBirdClientPresent) { return $true }

    if ($InstallClient) {
        Write-Log "NetBird client not found; installing (-InstallClient)." "INFO"
        return (Install-NetBirdClient)
    }

    if (Test-InteractiveSession) {
        # ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
        $answer = Read-Host "NetBird not found. Install now? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -match '^(y|yes)$') {
            return (Install-NetBirdClient)
        }
        Write-Log "NetBird client not found; installation declined by user." "WARN"
        return $false
    }

    Write-Log "NetBird client not found (service, '$(Get-NetBirdExePath)' or Chocolatey package '$PackageName'); not installing in non-interactive mode. Run with -InstallClient to install." "WARN"
    return $false
}

# -----------------------------
# GUI update logic
# -----------------------------
function Get-LatestNetBirdReleaseTag {
    Set-Tls12IfPossible
    $headers = Get-GitHubHeaders
    $api = "https://api.github.com/repos/netbirdio/netbird/releases/latest"
    $rel = Invoke-RestMethodCompat -Uri $api -Headers $headers
    $tag = ($rel.tag_name -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($tag)) { return $null }
    return $tag.TrimStart("v")
}

function Update-NetBirdGuiIfNeeded {
    param(
        [Parameter(Mandatory=$true)][string]$DaemonVersionAfterUpgrade
    )

    try {
        $latest = Get-LatestNetBirdReleaseTag
        if (-not $latest) {
            Write-Log "GUI update: failed to detect latest NetBird release; skipping." "WARN"
            return
        }

        $guiState = Read-JsonFile -Path $GuiStatePath
        $installedGui = $null
        if ($guiState -and $guiState.LastInstalledGuiVersion) {
            $installedGui = [string]$guiState.LastInstalledGuiVersion
        }

        if ($installedGui -eq $latest) {
            Write-Log "GUI update: already on latest GUI version ($latest)." "INFO"
            return
        }

        Write-Log "GUI update: installing GUI $latest (previous: $installedGui)..." "INFO"

        $url = "https://pkgs.netbird.io/windows/x64"
        $tmp = Join-Path $env:TEMP ("netbird-{0}.exe" -f $latest)

        Invoke-WebRequestCompat -Uri $url -Headers $null -OutFile $tmp | Out-Null

        # Never run an unsigned installer as SYSTEM. The NetBird signer was
        # checked against the installed netbird.exe (CN=NetBird GmbH, status Valid).
        $sig = Get-AuthenticodeSignature -FilePath $tmp
        $signerOk = $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -like "*CN=NetBird GmbH*")
        if ($sig.Status -ne "Valid" -or -not $signerOk) {
            Write-Log "GUI installer signature check failed (status: $($sig.Status)); not installing." "ERROR"
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
            return
        }

        $p = Start-Process -FilePath $tmp -ArgumentList "/S" -Wait -PassThru
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) {
            Write-Log "GUI installer returned exit code $($p.ExitCode). GUI state will NOT be updated." "ERROR"
            return
        }

        Write-JsonFile -Path $GuiStatePath -Object @{
            LastInstalledGuiVersion = $latest
            InstalledAtUtc          = (Get-Date).ToUniversalTime().ToString("o")
            DaemonVersionAtInstall  = $DaemonVersionAfterUpgrade
        }

        Write-Log "GUI update: installed successfully ($latest)." "INFO"
    } catch {
        Write-Log "GUI update failed: $($_.Exception.Message)" "WARN"
    }
}

# -----------------------------
# State (delayed upgrade)
# -----------------------------
function Get-OrInitState {
    $state = Read-JsonFile -Path $StatePath
    if (-not $state) {
        return @{
            CandidateVersion = $null
            FirstSeenUtc     = $null
            LastCheckUtc     = $null
        }
    }
    return $state
}

function Save-State {
    param($State)
    $State.LastCheckUtc = (Get-Date).ToUniversalTime().ToString("o")
    Write-JsonFile -Path $StatePath -Object $State
}

function Parse-RoundtripUtc {
    param([Parameter(Mandatory=$true)][string]$Value)
    try {
        return [DateTime]::ParseExact(
            $Value,
            "o",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        return $null
    }
}

# -----------------------------
# Scheduled Task management
# -----------------------------
function Install-NetBirdTask {
    Ensure-BaseDir

    $scriptPath = $PSCommandPath

    # NOTE: these are PowerShell.exe arguments (not script arguments)
    $runArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`"",
        "-DelayDays", $DelayDays,
        "-MaxRandomDelaySeconds", $MaxRandomDelaySeconds,
        "-LogRetentionDays", $LogRetentionDays,
        "-PackageName", "`"$PackageName`""
    )
    if ($NoSelfUpdate) { $runArgs += "-NoSelfUpdate" }

    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction -Execute $psExe -Argument ($runArgs -join " ")

    # Parse DailyTime (HH:mm) and build a DateTime for "today at HH:mm"
    try {
        $parsed = [DateTime]::ParseExact($DailyTime, "HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "Invalid -DailyTime value '$DailyTime'. Expected HH:mm (e.g. 23:59)."
    }

    # IMPORTANT: -At expects DateTime, not TimeSpan
    $at = (Get-Date).Date.Add($parsed.TimeOfDay)
    $trigger = New-ScheduledTaskTrigger -Daily -At $at

    $settings = New-ScheduledTaskSettingsSet
    if ($StartWhenAvailable) {
        $settings.StartWhenAvailable = $true
    }

    try {
        if ($RunAsCurrentUser) {
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        } else {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -User "SYSTEM" -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        }

        Write-Log "Scheduled Task installed/updated: $TaskName (daily at $DailyTime)." "INFO"
    } catch {
        Write-Log "Failed to install/update Scheduled Task '$TaskName': $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Uninstall-NetBirdTask {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log "Scheduled Task removed: $TaskName" "INFO"
    } catch {
        Write-Log "Scheduled Task not found or could not be removed: $($_.Exception.Message)" "WARN"
    }

    if ($RemoveState) {
        try {
            if (Test-Path $BaseDir) {
                Remove-Item -Path $BaseDir -Recurse -Force -ErrorAction Stop
                Write-Log "Removed state/logs directory: $BaseDir" "INFO"
            }
        } catch {
            Write-Log "Failed to remove state/logs directory: $($_.Exception.Message)" "WARN"
        }
    }
}

# -----------------------------
# Main
# -----------------------------
Ensure-BaseDir
Cleanup-OldLogs

if ($Install) {
    Write-Log "Mode: Install Scheduled Task" "INFO"
    if ($InstallClient -and -not (Confirm-NetBirdClient)) {
        Write-Log "NetBird client installation failed; the Scheduled Task is installed anyway." "WARN"
    }
    Install-NetBirdTask
    exit 0
}

if ($Uninstall) {
    Write-Log "Mode: Uninstall Scheduled Task" "INFO"
    Uninstall-NetBirdTask
    exit 0
}

Write-Log "Mode: Run" "INFO"

Try-SelfUpdate

if (-not (Confirm-NetBirdClient)) {
    exit 0
}

# Optional randomized delay
if ($MaxRandomDelaySeconds -gt 0) {
    $sleep = Get-Random -Minimum 0 -Maximum ($MaxRandomDelaySeconds + 1)
    if ($sleep -gt 0) {
        Write-Log "Random delay: sleeping for $sleep seconds..." "INFO"
        Start-Sleep -Seconds $sleep
    }
}

$installed = Get-ChocoLocalVersion -Pkg $PackageName
if (-not $installed) {
    Write-Log "Package '$PackageName' is not installed via Chocolatey; delayed daemon updates work only for Chocolatey installs. Exiting." "INFO"
    exit 0
}

$candidate = Get-ChocoRemoteVersion -Pkg $PackageName
if (-not $candidate) {
    Write-Log "Failed to detect remote version for '$PackageName'; exiting." "WARN"
    exit 0
}

Write-Log "Installed version: $installed" "INFO"
Write-Log "Candidate version: $candidate" "INFO"

$state = Get-OrInitState

# If candidate changed, reset aging window
if ($state.CandidateVersion -ne $candidate) {
    $state.CandidateVersion = $candidate
    $state.FirstSeenUtc = (Get-Date).ToUniversalTime().ToString("o")
    Write-Log "New candidate detected ($candidate). Aging window reset." "INFO"
}

$firstSeen = $null
if ($state.FirstSeenUtc) {
    $firstSeen = Parse-RoundtripUtc -Value ([string]$state.FirstSeenUtc)
}

if (-not $firstSeen) {
    $firstSeen = (Get-Date).ToUniversalTime()
    $state.FirstSeenUtc = $firstSeen.ToString("o")
}

$now = (Get-Date).ToUniversalTime()
$age = $now - $firstSeen
$ageDays = [math]::Max(0, [int][math]::Floor($age.TotalDays))

Write-Log ("Candidate age: {0} day(s) (DelayDays={1})" -f $ageDays, $DelayDays) "INFO"

Save-State -State $state

# Compare versions
$cmp = Compare-SemVer -A $candidate -B $installed
if ($cmp -le 0) {
    Write-Log "No upgrade needed (installed is up-to-date)." "INFO"
    exit 0
}

if ($ageDays -lt $DelayDays) {
    Write-Log "Upgrade is delayed; candidate has not aged long enough yet." "INFO"
    exit 0
}

# Upgrade
$ok = Upgrade-ChocoPackage -Pkg $PackageName -Version $candidate
if (-not $ok) {
    Write-Log "Upgrade failed; exiting." "ERROR"
    exit 1
}

$installedAfter = Get-ChocoLocalVersion -Pkg $PackageName
Write-Log "Installed version after upgrade: $installedAfter" "INFO"

Restart-NetBirdServiceIfPresent

# GUI update only if daemon changed this run
if ($installedAfter -and ($installedAfter -ne $installed)) {
    Update-NetBirdGuiIfNeeded -DaemonVersionAfterUpgrade $installedAfter
}

Write-Log "Done." "INFO"
exit 0
