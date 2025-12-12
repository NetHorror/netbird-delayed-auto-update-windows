# Version: 0.2.2

<#
.SYNOPSIS
    NetBird delayed auto-update (Windows/Chocolatey).

.DESCRIPTION
    Implements staged / delayed updates for the NetBird client installed via Chocolatey.
    A new Chocolatey package version must "age" for DelayDays before it can be installed.

    Optional features:
    - GUI update via official installer feed (pkgs.netbird.io)
    - Script self-update via GitHub releases of this repository
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
    [switch]$RunAsCurrentUser
)

# -----------------------------
# Constants / Paths
# -----------------------------
$ScriptVersion = "0.2.2"
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
        Uri     = $Uri
        Headers = $Headers
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
        Uri     = $Uri
        Headers = $Headers
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
    if ([string]::IsNullOrWhiteSpace($ScriptRepo)) { return }

    Set-Tls12IfPossible

    try {
        $headers = Get-GitHubHeaders
        $api = "https://api.github.com/repos/$ScriptRepo/releases/latest"
        $rel = Invoke-RestMethodCompat -Uri $api -Headers $headers
        $tag = ($rel.tag_name -as [string]).Trim()
        if ([string]::IsNullOrWhiteSpace($tag)) { return }

        $remoteVersion = $tag.TrimStart("v")
        $cmp = Compare-SemVer -A $remoteVersion -B $ScriptVersion
        if ($cmp -le 0) {
            Write-Log "Self-update: already on latest version ($ScriptVersion)." "INFO"
            return
        }

        Write-Log "Self-update: remote version is newer ($remoteVersion > $ScriptVersion). Attempting update..." "INFO"

        # If inside a git repo, prefer git pull.
        $gitDir = Join-Path (Split-Path -Parent $PSCommandPath) ".git"
        if (Test-Path $gitDir) {
            try {
                git pull --ff-only | Out-Null
                Write-Log "Self-update: updated via git pull." "INFO"
                return
            } catch {
                Write-Log "Self-update: git pull failed: $($_.Exception.Message). Falling back to raw download." "WARN"
            }
        }

        # Fallback: download script from the tagged version
        $rawUrl = "https://raw.githubusercontent.com/$ScriptRepo/$tag/$ScriptName"
        $tmp = Join-Path $env:TEMP ("{0}-{1}.tmp" -f $ScriptName, [Guid]::NewGuid().ToString("N"))
        Invoke-WebRequestCompat -Uri $rawUrl -Headers $headers -OutFile $tmp | Out-Null
        Move-Item -Path $tmp -Destination $PSCommandPath -Force
        Write-Log "Self-update: script updated from GitHub ($tag)." "INFO"
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
    param([string]$Pkg)
    try {
        Write-Log "Upgrading Chocolatey package '$Pkg'..." "INFO"
        & choco upgrade $Pkg -y --no-progress
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

    # Fallback: search by display name
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

        $p = Start-Process -FilePath $tmp -ArgumentList "/S" -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Write-Log "GUI installer returned exit code $($p.ExitCode). GUI state will NOT be updated." "ERROR"
            return
        }

        Write-JsonFile -Path $GuiStatePath -Object @{
            LastInstalledGuiVersion = $latest
            InstalledAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            DaemonVersionAtInstall = $DaemonVersionAfterUpgrade
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
        return [DateTime]::ParseExact($Value, "o", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
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
    $runArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`"",
        "-DelayDays", $DelayDays,
        "-MaxRandomDelaySeconds", $MaxRandomDelaySeconds,
        "-LogRetentionDays", $LogRetentionDays,
        "-PackageName", "`"$PackageName`""
    )

    # NOTE: switches are only included if enabled
    if ($StartWhenAvailable) {
        # This one affects task settings, not script args
        # kept for clarity
    }

    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    $action = New-ScheduledTaskAction -Execute $psExe -Argument ($runArgs -join " ")

    $triggerTime = [DateTime]::ParseExact($DailyTime, "HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
    $trigger = New-ScheduledTaskTrigger -Daily -At $triggerTime.TimeOfDay

    $settings = New-ScheduledTaskSettingsSet
    if ($StartWhenAvailable) {
        $settings.StartWhenAvailable = $true
    }

    if ($RunAsCurrentUser) {
        $principal = New-ScheduledTaskPrincipal -UserId "$env:UserDomain\$env:UserName" -LogonType S4U -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    } else {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    }

    Write-Log "Scheduled Task installed/updated: $TaskName (daily at $DailyTime)." "INFO"
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
    Write-Log "Package '$PackageName' is not installed via Chocolatey; exiting." "INFO"
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
$ok = Upgrade-ChocoPackage -Pkg $PackageName
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
