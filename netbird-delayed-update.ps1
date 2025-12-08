# Version: 0.2.0

<#
.SYNOPSIS
    NetBird delayed auto-update for Windows (Chocolatey) + GUI updater + script self-update.

.DESCRIPTION
    Implements staged / delayed updates for the NetBird client installed via Chocolatey.
    A new NetBird version in the Chocolatey repository must "age" for DelayDays before
    it is allowed to be installed. Short-lived / bad releases that get replaced quickly
    will never be deployed to clients.

    Additionally, this script:
      - Updates the NetBird GUI:
          * Reads the latest release tag from GitHub (only to know the version number).
          * Downloads the latest Windows x64 installer from https://pkgs.netbird.io/windows/x64.
          * Installs it silently (/S).
          * Stores the last GUI version in gui-state.json to avoid reinstalling the same version.
      - Can self-update:
          * Reads the latest release from GitHub for this repository.
          * Compares release tag (X.Y.Z) with local $ScriptVersion.
          * If newer, tries "git pull" if the script is inside a git repo.
          * If git is unavailable or not a repo, downloads the script from raw GitHub for that tag.

    Script modes:
      -Run      (default) : perform delayed-update check and optional upgrade (daemon + GUI).
      -Install           : create / update the scheduled task that runs this script daily.
      -Uninstall         : remove the scheduled task (and optionally state/logs).

.PARAMETER Install
    Install or update the scheduled task that runs this script daily in Run mode.

.PARAMETER Uninstall
    Remove the scheduled task and optionally delete state/logs.

.PARAMETER RemoveState
    When used with -Uninstall, also delete C:\ProgramData\NetBirdDelayedUpdate (state & logs).

.PARAMETER StartWhenAvailable
    If the task is missed (e.g. computer was turned off), run the task as soon as possible
    instead of waiting until the next scheduled time. Equivalent to Task Scheduler's
    "Run task as soon as possible after a scheduled start is missed".

.PARAMETER DelayDays
    Minimum number of days that a NetBird version must be present in the Chocolatey repo
    before it can be installed. Defaults to 10 days.
    If 0, versions are installed as soon as they appear in the repo (no delay).

.PARAMETER MaxRandomDelaySeconds
    Maximum random delay (in seconds) added before each Run-mode check.
    This helps to avoid all machines hitting the repo at once. Default: 3600 (1 hour).
    If set to 0, no random delay is added.

.PARAMETER DailyTime
    Time of day (HH:mm) when the scheduled task should run. Default: "04:00".

.PARAMETER TaskName
    Human-readable name of the scheduled task. Default: "NetBird Delayed Choco Update".

.PARAMETER RunAsCurrentUser
    If set together with -Install, the task is created to run as the current user
    with highest privileges. If not set, the task runs as SYSTEM.

.PARAMETER PackageName
    Chocolatey package name (defaults to "netbird").
#>

[CmdletBinding(DefaultParameterSetName = "Run")]
param(
    [Alias("i")][switch]$Install,
    [Alias("u")][switch]$Uninstall,
    [switch]$RemoveState,

    [Alias("r")][switch]$StartWhenAvailable,

    [int]$DelayDays = 10,
    [int]$MaxRandomDelaySeconds = 3600,
    [string]$DailyTime = "04:00",
    [string]$TaskName = "NetBird Delayed Choco Update",
    [switch]$RunAsCurrentUser,

    [string]$PackageName = "netbird"
)

# ------------------ CONSTANTS / PATHS ------------------

$StateDir  = "C:\ProgramData\NetBirdDelayedUpdate"
$StateFile = Join-Path $StateDir "state.json"
$LogDir    = $StateDir

# ------------- Script self-update settings -------------

# Local script version. Bump this on every script release.
# Example: 0.2.0, 0.2.1, 0.3.0 (no leading 'v').
$ScriptVersion = [version]"0.2.0"

# GitHub repository that hosts this script (owner/repo).
$ScriptRepo = "NetHorror/netbird-delayed-auto-update-windows"

# Path to this script inside the repo (used for HTTP fallback).
$ScriptRelativePath = "netbird-delayed-update.ps1"

# will be initialised later when we know we are in Run mode
$script:LogFile = $null

function Ensure-StateDir {
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
}

# ------------------ LOGGING & STATE ------------------

function Write-Log {
    param([string]$Message)

    Ensure-StateDir

    if (-not $script:LogFile) {
        $script:LogFile = Join-Path $LogDir ("netbird-delayed-update-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    }

    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} {1}" -f $ts, $Message

    Write-Host $line
    Add-Content -Path $script:LogFile -Value $line
}

function Load-State {
    if (-not (Test-Path $StateFile)) {
        return $null
    }

    try {
        $json = Get-Content $StateFile -Raw
        if (-not $json) { return $null }

        return $json | ConvertFrom-Json
    }
    catch {
        Write-Log ("WARNING: Failed to read/parse state file '{0}': {1}" -f $StateFile, $_.Exception.Message)
        return $null
    }
}

function Save-State {
    param(
        [Parameter(Mandatory=$true)][string]$CandidateVersion,
        [Parameter(Mandatory=$true)][DateTime]$FirstSeenUtc,
        [Parameter(Mandatory=$true)][DateTime]$LastCheckUtc
    )

    Ensure-StateDir

    $state = [PSCustomObject]@{
        CandidateVersion = $CandidateVersion
        FirstSeenUtc     = $FirstSeenUtc.ToString("o")
        LastCheckUtc     = $LastCheckUtc.ToString("o")
    }

    try {
        $json = $state | ConvertTo-Json -Depth 4
        $json | Set-Content -Path $StateFile -Encoding UTF8
    }
    catch {
        Write-Log ("WARNING: Failed to write state file '{0}': {1}" -f $StateFile, $_.Exception.Message)
    }
}

# ------------------ SELF-UPDATE VIA RELEASE + GIT ------------------

function Invoke-SelfUpdateByRelease {

    if (-not $ScriptRepo) {
        return
    }

    try {
        # Determine local script path
        $localPath = $PSCommandPath
        if (-not $localPath) {
            $localPath = $MyInvocation.PSCommandPath
        }
        if (-not $localPath -or -not (Test-Path $localPath)) {
            Write-Log "Self-update: cannot determine local script path; skipping."
            return
        }

        # 1) Get latest release from GitHub
        $releaseUrl = "https://api.github.com/repos/$ScriptRepo/releases/latest"
        Write-Log "Self-update: checking latest script release at $releaseUrl"

        $rel = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing

        # Tag is plain version number like "0.2.0" (no leading 'v')
        if ($rel.tag_name -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)$') {
            Write-Log ("Self-update: cannot parse release tag '{0}' as X.Y.Z; skipping." -f $rel.tag_name)
            return
        }

        $remoteVersion = [version]$Matches[1]
        Write-Log ("Self-update: local script version {0}, latest release {1}" -f $ScriptVersion, $remoteVersion)

        if ($remoteVersion -le $ScriptVersion) {
            Write-Log "Self-update: script is up to date."
            return
        }

        Write-Log "Self-update: newer script version available."

        # 2) Try git pull if git is available and script is inside a git repo
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        $didGitUpdate = $false

        if ($git) {
            # Find repo root by walking up until we see .git
            $repoDir = Split-Path -Parent $localPath
            while ($repoDir -and -not (Test-Path (Join-Path $repoDir '.git'))) {
                $parent = Split-Path -Parent $repoDir
                if ($parent -eq $repoDir) { $repoDir = $null; break }
                $repoDir = $parent
            }

            if ($repoDir) {
                Write-Log ("Self-update: running 'git pull --ff-only' in {0}" -f $repoDir)
                & git -C $repoDir pull --ff-only
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Self-update: git pull completed. New script will be used on next run."
                    $didGitUpdate = $true
                }
                else {
                    Write-Log ("Self-update: git pull failed with exit code {0}." -f $LASTEXITCODE)
                }
            }
            else {
                Write-Log "Self-update: script is not inside a git repository."
            }
        }
        else {
            Write-Log "Self-update: git.exe not found in PATH."
        }

        if ($didGitUpdate) {
            return
        }

        # 3) HTTP fallback: download script from raw GitHub URL for this tag
        $rawUrl = "https://raw.githubusercontent.com/$ScriptRepo/$($rel.tag_name)/$ScriptRelativePath"
        Write-Log ("Self-update: downloading script from {0}" -f $rawUrl)

        $tmp = [System.IO.Path]::GetTempFileName()
        Invoke-WebRequest -Uri $rawUrl -OutFile $tmp -UseBasicParsing

        Copy-Item $tmp $localPath -Force
        Remove-Item $tmp -ErrorAction SilentlyContinue

        Write-Log "Self-update: script updated from raw GitHub. New version will be used on next run."
    }
    catch {
        Write-Log ("Self-update: failed: {0}" -f $_.Exception.Message)
    }
}

# ------------------ MODE: INSTALL TASK ------------------

function Install-NetBirdTask {

    Write-Host "Installing / updating scheduled task '$TaskName' for NetBird delayed updates..."

    # Full path to this script
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.PSCommandPath
    }

    if (-not $scriptPath) {
        Write-Error "Cannot determine script path. Are you running from an interactive session without a file?"
        return
    }

    # Validate DailyTime (HH:mm)
    if ($DailyTime -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') {
        throw "Invalid DailyTime format '$DailyTime'. Expected HH:mm (24-hour)."
    }

    $startTime = [DateTime]::ParseExact($DailyTime, "HH:mm", $null)

    # Build argument string for Run mode
    $argList = @()
    $argList += "-ExecutionPolicy Bypass"
    $argList += "-File `"$scriptPath`""
    $argList += "-DelayDays $DelayDays"
    $argList += "-MaxRandomDelaySeconds $MaxRandomDelaySeconds"
    $argList += "-PackageName `"$PackageName`""

    # No need to pass Install/Uninstall to the scheduled run
    $arguments = $argList -join " "

    Write-Host "Task will run command:"
    Write-Host "  powershell.exe $arguments"

    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Daily -At $startTime

    if ($RunAsCurrentUser) {
        $user = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
        Write-Host "The task will run as current user: $user (with highest privileges)."
        $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest
    }
    else {
        Write-Host "The task will run as SYSTEM (with highest privileges)."
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    }

    # Settings (StartWhenAvailable controlled by -StartWhenAvailable / -r)
    if ($StartWhenAvailable) {
        Write-Host 'The task will run as soon as possible after a missed start (StartWhenAvailable = true).'
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
    }
    else {
        $settings = New-ScheduledTaskSettingsSet
    }

    # Remove existing task if present
    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Existing task '$TaskName' found. Removing..."
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
    catch {
        Write-Warning ("Failed to check/remove existing task '{0}': {1}" -f $TaskName, $_.Exception.Message)
    }

    # Register new task
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "NetBird delayed Chocolatey update"
        Write-Host "Scheduled task '$TaskName' installed/updated successfully."
    }
    catch {
        Write-Error ("Failed to register scheduled task '{0}': {1}" -f $TaskName, $_.Exception.Message)
    }
}

# ------------------ MODE: UNINSTALL TASK ------------------

function Uninstall-NetBirdTask {

    Write-Host "Uninstalling scheduled task '$TaskName'..."

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Task '$TaskName' removed."
        }
        else {
            Write-Host "Task '$TaskName' not found. Nothing to remove."
        }
    }
    catch {
        Write-Warning ("Failed to remove task '{0}': {1}" -f $TaskName, $_.Exception.Message)
    }

    if ($RemoveState) {
        Write-Host "Removing state/log directory '$StateDir'..."

        try {
            if (Test-Path $StateDir) {
                Remove-Item -Path $StateDir -Recurse -Force
                Write-Host "Directory '$StateDir' removed."
            }
            else {
                Write-Host "Directory '$StateDir' not found, skipping."
            }
        }
        catch {
            Write-Warning ("Failed to remove '{0}': {1}" -f $StateDir, $_.Exception.Message)
        }
    }

    Write-Host "Done."
}

# ------------------ MODE: RUN (DELAYED UPDATE LOGIC) ------------------

function Invoke-NetBirdDelayedUpdate {
    $exitCode = 0

    Ensure-StateDir

    Write-Log "=== NetBird delayed update started ==="
    Write-Log "Parameters: DelayDays=$DelayDays, MaxRandomDelaySeconds=$MaxRandomDelaySeconds, PackageName=$PackageName"

    # Random delay to spread out load on Chocolatey repo
    if ($MaxRandomDelaySeconds -gt 0) {
        $delay = Get-Random -Minimum 0 -Maximum $MaxRandomDelaySeconds
        Write-Log "Random delay before version check: $delay seconds."
        Start-Sleep -Seconds $delay
    }
    else {
        Write-Log "Random delay disabled (MaxRandomDelaySeconds=0)."
    }

    # Query locally installed version via choco
    try {
        $installedOutput = choco list --localonly $PackageName 2>$null
    }
    catch {
        Write-Log ("ERROR: Failed to execute 'choco list --localonly {0}': {1}" -f $PackageName, $_.Exception.Message)
        return 1
    }

    $installedVersionString = $null
    foreach ($line in $installedOutput) {
        # Typical: "netbird 0.60.7"
        if ($line -match "^\s*${PackageName}\s+([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)") {
            $installedVersionString = $Matches[1]
            break
        }
    }

    if (-not $installedVersionString) {
        Write-Log ("Package '{0}' is not installed locally. Nothing to update. Exiting." -f $PackageName)
        return 0
    }

    Write-Log "Installed $PackageName version: $installedVersionString"

    # Query latest version from choco repo
    try {
        $infoOutput = choco info $PackageName 2>$null
    }
    catch {
        Write-Log ("ERROR: Failed to execute 'choco info {0}': {1}" -f $PackageName, $_.Exception.Message)
        return 1
    }

    $candidateVersionString = $null
    foreach ($line in $infoOutput) {
        # Typical: "Latest   : 0.60.7"
        if ($line -match "Latest\s*:\s*([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)") {
            $candidateVersionString = $Matches[1]
            break
        }
    }

    if (-not $candidateVersionString) {
        Write-Log "ERROR: Could not determine candidate version from 'choco info $PackageName'."
        return 1
    }

    Write-Log ("Repository candidate version for {0}: {1}" -f $PackageName, $candidateVersionString)

    # Parse versions
    try {
        $installedVersion = [version]$installedVersionString
        $candidateVersion = [version]$candidateVersionString
    }
    catch {
        Write-Log ("ERROR: Failed to parse versions. Installed='{0}', Repo='{1}'." -f $installedVersionString, $candidateVersionString)
        return 1
    }

    $nowUtc = [DateTime]::UtcNow

    # Load previous state
    $state = Load-State
    if ($null -eq $state -or $state.CandidateVersion -ne $candidateVersionString) {
        Write-Log "New candidate version detected (or no previous state). Resetting aging timer."
        $firstSeenUtc = $nowUtc
    }
    else {
        try {
            $firstSeenUtc = [DateTime]::Parse($state.FirstSeenUtc)
        }
        catch {
            Write-Log "WARNING: Failed to parse FirstSeenUtc from state. Resetting to now."
            $firstSeenUtc = $nowUtc
        }
    }

    # Compute age
    $age = $nowUtc - $firstSeenUtc
    $ageDays = [Math]::Round($age.TotalDays, 2)
    Write-Log "Candidate version age: $ageDays days (DelayDays=$DelayDays)."

    # If DelayDays > 0 and candidate version is too new, skip upgrade
    if ($DelayDays -gt 0 -and $age.TotalDays -lt $DelayDays) {
        Write-Log "Version has not aged long enough. Skipping upgrade."
        Save-State -CandidateVersion $candidateVersionString -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc
        return 0
    }

    # Age is enough, check if we actually need to upgrade
    if ($installedVersion -ge $candidateVersion) {
        Write-Log "Local version $installedVersionString is already >= candidate $candidateVersionString. No upgrade required."
        Save-State -CandidateVersion $candidateVersionString -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc
        return 0
    }

    Write-Log "Version aged enough and upgrade is required: $installedVersionString -> $candidateVersionString."

    # Try to stop NetBird service (if present)
    try {
        $svc = Get-Service -Name Netbird -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Log "Stopping NetBird service..."
            Stop-Service -Name Netbird -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
        else {
            Write-Log "NetBird service is not running or not found. Skipping stop."
        }
    }
    catch {
        Write-Log ("WARNING: Failed to stop NetBird service: {0}" -f $_.Exception.Message)
    }

    # Run choco upgrade
    Write-Log "Running: choco upgrade $PackageName -y --no-progress"
    & choco upgrade $PackageName -y --no-progress
    $chocoExit = $LASTEXITCODE

    if ($chocoExit -ne 0) {
        Write-Log ("ERROR: 'choco upgrade' returned exit code {0}." -f $chocoExit)
        $exitCode = $chocoExit
    }
    else {
        Write-Log "Chocolatey upgrade completed successfully."

        # Try to start NetBird service again (if it exists)
        try {
            $svc = Get-Service -Name Netbird -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                Write-Log "Starting NetBird service..."
                Start-Service -Name Netbird -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Log ("WARNING: Failed to start NetBird service: {0}" -f $_.Exception.Message)
        }
    }

    # Save updated state
    Save-State -CandidateVersion $candidateVersionString -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc

    Write-Log "=== NetBird delayed update finished ==="
    return $exitCode
}

# ------------------ GUI UPDATE (SEPARATE FROM CHOCO) ------------------

function Invoke-NetBirdGuiUpdate {

    Ensure-StateDir

    $guiStateFile = Join-Path $StateDir "gui-state.json"
    $guiState = $null

    # Load GUI state if present
    if (Test-Path $guiStateFile) {
        try {
            $guiState = Get-Content $guiStateFile -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log ("Failed to parse gui-state.json, it will be recreated. {0}" -f $_.Exception.Message)
            $guiState = $null
        }
    }

    # Get latest release tag from GitHub (only for version number)
    $releaseUrl = "https://api.github.com/repos/netbirdio/netbird/releases/latest"
    Write-Log "Checking latest NetBird release on GitHub (for GUI update)..."

    try {
        $latestRelease = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing
    }
    catch {
        Write-Log ("GitHub API call failed (GUI update skipped): {0}" -f $_.Exception.Message)
        return
    }

    $releaseVersion = $null
    if ($latestRelease.tag_name -match 'v?([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
        $releaseVersion = $Matches[1]
    }

    if (-not $releaseVersion) {
        Write-Log ("Could not parse GUI release version from tag '{0}'. Skipping GUI update." -f $latestRelease.tag_name)
        return
    }

    Write-Log "Latest NetBird GUI release version (GitHub tag): $releaseVersion"

    # If we already installed this GUI version according to gui-state.json, nothing to do
    if ($guiState -and $guiState.LastGuiVersion -eq $releaseVersion) {
        Write-Log "GUI already updated to version $releaseVersion according to gui-state.json – skipping GUI installer."
        return
    }

    # Actual installer is served from pkgs.netbird.io, not from GitHub assets
    $installerUrl  = "https://pkgs.netbird.io/windows/x64"   # always points to latest x64 installer
    $installerName = "netbird-latest-windows-x64.exe"
    $installerPath = Join-Path $env:TEMP $installerName

    Write-Log "Downloading NetBird GUI installer from $installerUrl -> $installerPath"

    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    }
    catch {
        Write-Log ("Failed to download GUI installer: {0}" -f $_.Exception.Message)
        return
    }

    # Run silent installer
    try {
        Write-Log "Running GUI installer silently (/S)..."
        Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
        Write-Log "GUI installer finished successfully."
    }
    catch {
        Write-Log ("GUI installer process failed: {0}" -f $_.Exception.Message)
        return
    }
    finally {
        try {
            Remove-Item $installerPath -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log ("Failed to remove temporary GUI installer file: {0}" -f $_.Exception.Message)
        }
    }

    # Save GUI state so we do not reinstall the same version every run
    $guiState = [pscustomobject]@{
        LastGuiVersion   = $releaseVersion
        LastGuiUpdateUtc = [DateTime]::UtcNow
    }

    try {
        $guiState | ConvertTo-Json -Depth 4 | Set-Content -Path $guiStateFile -Encoding UTF8
        Write-Log "GUI state updated: version $releaseVersion."
    }
    catch {
        Write-Log ("Failed to write gui-state.json: {0}" -f $_.Exception.Message)
    }
}

# ------------------ MAIN DISPATCH ------------------

if ($Install) {
    Install-NetBirdTask
    exit 0
}

if ($Uninstall) {
    Uninstall-NetBirdTask
    exit 0
}

# Optional: check for newer script version by GitHub release and update itself.
# New version will be used on the next run.
Invoke-SelfUpdateByRelease

# Default: run update logic once (daemon + GUI)
$code = Invoke-NetBirdDelayedUpdate
Invoke-NetBirdGuiUpdate
exit $code
