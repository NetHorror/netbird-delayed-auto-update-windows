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

$ScriptVersion = [version]"0.2.0"
$ScriptRepo = "NetHorror/netbird-delayed-auto-update-windows"
$ScriptRelativePath = "netbird-delayed-update.ps1"

# globals for this run
$script:LogFile          = $null
$script:NetBirdInstalled = $false
$script:NetBirdUpgraded  = $false

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
        $msg = "WARNING: Failed to read/parse state file '{0}': {1}" -f $StateFile, $_.Exception.Message
        Write-Log $msg
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
        $msg = "WARNING: Failed to write state file '{0}': {1}" -f $StateFile, $_.Exception.Message
        Write-Log $msg
    }
}

# ------------------ SELF-UPDATE VIA RELEASE + GIT ------------------

function Invoke-SelfUpdateByRelease {

    if (-not $ScriptRepo) {
        return
    }

    try {
        $localPath = $PSCommandPath
        if (-not $localPath) {
            $localPath = $MyInvocation.PSCommandPath
        }
        if (-not $localPath -or -not (Test-Path $localPath)) {
            Write-Log "Self-update: cannot determine local script path; skipping."
            return
        }

        $releaseUrl = "https://api.github.com/repos/$ScriptRepo/releases/latest"
        Write-Log "Self-update: checking latest script release at $releaseUrl"

        $rel = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing

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

        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        $didGitUpdate = $false

        if ($git) {
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

        $rawUrl = "https://raw.githubusercontent.com/$ScriptRepo/$($rel.tag_name)/$ScriptRelativePath"
        Write-Log ("Self-update: downloading script from {0}" -f $rawUrl)

        $tmp = [System.IO.Path]::GetTempFileName()
        Invoke-WebRequest -Uri $rawUrl -OutFile $tmp -UseBasicParsing

        Copy-Item $tmp $localPath -Force
        Remove-Item $tmp -ErrorAction SilentlyContinue

        Write-Log "Self-update: script updated from raw GitHub. New version will be used on next run."
    }
    catch {
        $msg = "Self-update: failed: {0}" -f $_.Exception.Message
        Write-Log $msg
    }
}

# ------------------ MODE: INSTALL TASK ------------------

function Install-NetBirdTask {

    Write-Host "Installing / updating scheduled task '$TaskName' for NetBird delayed updates..."

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.PSCommandPath
    }

    if (-not $scriptPath) {
        Write-Error "Cannot determine script path. Are you running from an interactive session without a file?"
        return
    }

    if ($DailyTime -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') {
        throw "Invalid DailyTime format '$DailyTime'. Expected HH:mm (24-hour)."
    }

    $startTime = [DateTime]::ParseExact($DailyTime, "HH:mm", $null)

    $argList = @()
    $argList += "-ExecutionPolicy Bypass"
    $argList += "-File `"$scriptPath`""
    $argList += "-DelayDays $DelayDays"
    $argList += "-MaxRandomDelaySeconds $MaxRandomDelaySeconds"
    $argList += "-PackageName `"$PackageName`""

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

    if ($StartWhenAvailable) {
        Write-Host "The task will run as soon as possible after a missed start (StartWhenAvailable = true)."
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
    }
    else {
        $settings = New-ScheduledTaskSettingsSet
    }

    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Existing task '$TaskName' found. Removing..."
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
    catch {
        $msg = "Failed to check/remove existing task '{0}': {1}" -f $TaskName, $_.Exception.Message
        Write-Warning $msg
    }

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "NetBird delayed Chocolatey update"
        Write-Host "Scheduled task '$TaskName' installed/updated successfully."
    }
    catch {
        $msg = "Failed to register scheduled task '{0}': {1}" -f $TaskName, $_.Exception.Message
        Write-Error $msg
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
        $msg = "Failed to remove task '{0}': {1}" -f $TaskName, $_.Exception.Message
        Write-Warning $msg
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
            $msg = "Failed to remove '{0}': {1}" -f $StateDir, $_.Exception.Message
            Write-Warning $msg
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

    $script:NetBirdInstalled = $false
    $script:NetBirdUpgraded  = $false

    if ($MaxRandomDelaySeconds -gt 0) {
        $delay = Get-Random -Minimum 0 -Maximum $MaxRandomDelaySeconds
        Write-Log "Random delay before version check: $delay seconds."
        Start-Sleep -Seconds $delay
    }
    else {
        Write-Log "Random delay disabled (MaxRandomDelaySeconds=0)."
    }

    # -------- Installed version (local) --------
    try {
        $installedOutput = choco list --localonly $PackageName --exact --limit-output 2>$null
    }
    catch {
        $msg = "ERROR: Failed to execute 'choco list --localonly {0} --exact --limit-output': {1}" -f $PackageName, $_.Exception.Message
        Write-Log $msg
        return 1
    }

    $installedVersionString = $null
    if ($installedOutput) {
        $escapedName = [Regex]::Escape($PackageName)
        foreach ($line in $installedOutput) {
            # Example: "netbird|0.60.7"
            if ($line -match ("^\s*{0}\|([^\|]+)" -f $escapedName)) {
                $installedVersionString = $Matches[1].Trim()
                break
            }
        }
    }

    if (-not $installedVersionString) {
        Write-Log ("Package '{0}' is not installed locally. Nothing to update. Exiting." -f $PackageName)
        $script:NetBirdInstalled = $false
        return 0
    }

    $script:NetBirdInstalled = $true
    Write-Log "Installed $PackageName version: $installedVersionString"

    # -------- Candidate version in repo --------
    try {
        $repoOutput = choco search $PackageName --exact --limit-output 2>$null
    }
    catch {
        $msg = "ERROR: Failed to execute 'choco search {0} --exact --limit-output': {1}" -f $PackageName, $_.Exception.Message
        Write-Log $msg
        return 1
    }

    $candidateVersionString = $null
    if ($repoOutput) {
        $escapedName = [Regex]::Escape($PackageName)
        foreach ($line in $repoOutput) {
            # Example: "netbird|0.60.7|https://community.chocolatey.org/packages/netbird"
            if ($line -match ("^\s*{0}\|([^\|]+)" -f $escapedName)) {
                $candidateVersionString = $Matches[1].Trim()
                break
            }
        }
    }

    if (-not $candidateVersionString) {
        Write-Log "ERROR: Could not determine candidate version from 'choco search'."
        return 1
    }

    Write-Log ("Repository candidate version for {0}: {1}" -f $PackageName, $candidateVersionString)

    try {
        $installedVersion = [version]$installedVersionString
        $candidateVersion = [version]$candidateVersionString
    }
    catch {
        Write-Log ("ERROR: Failed to parse versions. Installed='{0}', Repo='{1}'." -f $installedVersionString, $candidateVersionString)
        return 1
    }

    $nowUtc = [DateTime]::UtcNow

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

    $age = $nowUtc - $firstSeenUtc
    $ageDays = [Math]::Round($age.TotalDays, 2)
    Write-Log "Candidate version age: $ageDays days (DelayDays=$DelayDays)."

    if ($DelayDays -gt 0 -and $age.TotalDays -lt $DelayDays) {
        Write-Log "Version has not aged long enough. Skipping upgrade."
        Save-State -CandidateVersion $candidateVersionString -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc
        return 0
    }

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
        $msg = "WARNING: Failed to stop NetBird service: {0}" -f $_.Exception.Message
        Write-Log $msg
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
        $script:NetBirdUpgraded = $true

        try {
            $svc = Get-Service -Name Netbird -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                Write-Log "Starting NetBird service..."
                Start-Service -Name Netbird -ErrorAction SilentlyContinue
            }
        }
        catch {
            $msg = "WARNING: Failed to start NetBird service: {0}" -f $_.Exception.Message
            Write-Log $msg
        }
    }

    Save-State -CandidateVersion $candidateVersionString -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc

    Write-Log "=== NetBird delayed update finished ==="
    return $exitCode
}

# ------------------ GUI UPDATE (SEPARATE FROM CHOCO) ------------------

function Invoke-NetBirdGuiUpdate {

    Ensure-StateDir

    $guiStateFile = Join-Path $StateDir "gui-state.json"
    $guiState = $null

    if (Test-Path $guiStateFile) {
        try {
            $guiState = Get-Content $guiStateFile -Raw | ConvertFrom-Json
        }
        catch {
            $msg = "Failed to parse gui-state.json, it will be recreated. {0}" -f $_.Exception.Message
            Write-Log $msg
            $guiState = $null
        }
    }

    $releaseUrl = "https://api.github.com/repos/netbirdio/netbird/releases/latest"
    Write-Log "Checking latest NetBird release on GitHub (for GUI update)..."

    try {
        $latestRelease = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing
    }
    catch {
        $msg = "GitHub API call failed (GUI update skipped): {0}" -f $_.Exception.Message
        Write-Log $msg
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

    if ($guiState -and $guiState.LastGuiVersion -eq $releaseVersion) {
        Write-Log "GUI already updated to version $releaseVersion according to gui-state.json - skipping GUI installer."
        return
    }

    $installerUrl  = "https://pkgs.netbird.io/windows/x64"
    $installerName = "netbird-latest-windows-x64.exe"
    $installerPath = Join-Path $env:TEMP $installerName

    Write-Log "Downloading NetBird GUI installer from $installerUrl -> $installerPath"

    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    }
    catch {
        $msg = "Failed to download GUI installer: {0}" -f $_.Exception.Message
        Write-Log $msg
        return
    }

    try {
        Write-Log "Running GUI installer silently (/S)..."
        Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
        Write-Log "GUI installer finished successfully."
    }
    catch {
        $msg = "GUI installer process failed: {0}" -f $_.Exception.Message
        Write-Log $msg
        return
    }
    finally {
        try {
            Remove-Item $installerPath -ErrorAction SilentlyContinue
        }
        catch {
            $msg = "Failed to remove temporary GUI installer file: {0}" -f $_.Exception.Message
            Write-Log $msg
        }
    }

    $guiState = [pscustomobject]@{
        LastGuiVersion   = $releaseVersion
        LastGuiUpdateUtc = [DateTime]::UtcNow
    }

    try {
        $guiState | ConvertTo-Json -Depth 4 | Set-Content -Path $guiStateFile -Encoding UTF8
        Write-Log "GUI state updated: version $releaseVersion."
    }
    catch {
        $msg = "Failed to write gui-state.json: {0}" -f $_.Exception.Message
        Write-Log $msg
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

Invoke-SelfUpdateByRelease

$script:NetBirdInstalled = $false
$script:NetBirdUpgraded  = $false

$code = Invoke-NetBirdDelayedUpdate

if ($script:NetBirdInstalled -and $script:NetBirdUpgraded) {
    Invoke-NetBirdGuiUpdate
} elseif (-not $script:NetBirdInstalled) {
    Write-Log "Skipping GUI update because NetBird is not installed."
} else {
    Write-Log "Skipping GUI update because NetBird version did not change."
}

exit $code
