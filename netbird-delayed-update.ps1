<#
.SYNOPSIS
    NetBird delayed auto-update for Windows (Chocolatey).

.DESCRIPTION
    Implements staged / delayed updates for the NetBird client installed via Chocolatey.
    A new NetBird version in the Chocolatey repository must "age" for DelayDays before
    it is allowed to be installed. Short-lived / bad releases that get replaced quickly
    will never be deployed to clients.

    This script has three modes:
      -Run      (default) : perform a single delayed-update check and optional upgrade.
                             Used by Task Scheduler.
      -Install           : create / update the scheduled task that runs this script daily.
      -Uninstall         : remove the scheduled task (and optionally state/logs).

.PARAMETER Install
    Install or update the scheduled task. Short alias: -i.

.PARAMETER Uninstall
    Remove the scheduled task. Can be combined with -RemoveState. Short alias: -u.

.PARAMETER RemoveState
    When used with -Uninstall, also delete C:\ProgramData\NetBirdDelayedUpdate
    (state.json and log files).

.PARAMETER DelayDays
    How many days a new candidate version must stay unchanged in the Chocolatey
    repository before it can be installed.

.PARAMETER MaxRandomDelaySeconds
    Maximum random delay (in seconds) added before each run. This is used to spread
    the update time across machines. When non-zero, Task Scheduler may show the
    task in "Running" state (LastRunResult = 0x41301) while the script is simply
    sleeping before doing its checks.

.PARAMETER DailyTime
    Time of day (HH:mm, 24-hour) when the scheduled task should start.

.PARAMETER TaskName
    Name of the scheduled task.

.PARAMETER RunAsCurrentUser
    By default the task runs as SYSTEM. If this switch is specified, the task
    will run as the current user with highest privileges.

.PARAMETER PackageName
    Chocolatey package name (defaults to "netbird").

.EXAMPLE
    # Install scheduled task with defaults
    .\netbird-delayed-update.ps1 -Install

.EXAMPLE
    # Install task that waits 5 days and uses no random delay
    .\netbird-delayed-update.ps1 -Install -DelayDays 5 -MaxRandomDelaySeconds 0

.EXAMPLE
    # Uninstall task but keep state/logs
    .\netbird-delayed-update.ps1 -Uninstall

.EXAMPLE
    # Uninstall task and remove state/log directory
    .\netbird-delayed-update.ps1 -Uninstall -RemoveState

.EXAMPLE
    # Run a single check immediately (no delay) for manual testing
    .\netbird-delayed-update.ps1 -DelayDays 0 -MaxRandomDelaySeconds 0

.NOTES
    Task Scheduler status codes:
      - 0x0      : last run finished successfully
      - 0x41301  : the task is currently running (for this script it usually means
                  it is sleeping inside the random delay before doing checks)
#>

param(
    [Alias("i")][switch]$Install,
    [Alias("u")][switch]$Uninstall,
    [switch]$RemoveState,

    [int]$DelayDays = 3,
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
    $line = "[$ts] $Message"
    $line | Tee-Object -FilePath $script:LogFile -Append | Out-Null
}

function Load-State {
    if (-not (Test-Path $StateFile)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $StateFile -Raw
        if (-not $raw) { return $null }
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Log "WARNING: Failed to read state file '$StateFile': $($_.Exception.Message)."
        return $null
    }
}

function Save-State {
    param(
        [string]$CandidateVersion,
        [datetime]$FirstSeenUtc,
        [datetime]$LastCheckUtc
    )

    Ensure-StateDir

    $obj = [PSCustomObject]@{
        CandidateVersion = $CandidateVersion
        FirstSeenUtc     = $FirstSeenUtc.ToString("o")
        LastCheckUtc     = $LastCheckUtc.ToString("o")
    }

    try {
        $obj | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    }
    catch {
        Write-Log "WARNING: Failed to write state file '$StateFile': $($_.Exception.Message)."
    }
}

# ------------------ CHOCO HELPERS ------------------

function Get-ChocoVersionString {
    param(
        [string]$Name,
        [switch]$Local
    )

    $cmd = "choco"
    $args = @()

    if ($Local) {
        $args += "list"
        $args += $Name
        $args += "--local-only"
    }
    else {
        $args += "search"
        $args += $Name
    }

    $args += "--limit-output"
    $args += "--exact"

    $output = & $cmd @args 2>$null
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -or -not $output) {
        return $null
    }

    foreach ($line in $output) {
        if ($line -match "^\s*$([regex]::Escape($Name))\|(.+)$") {
            return $matches[1].Trim()
        }
    }

    return $null
}

# ------------------ MODE: INSTALL TASK ------------------

function Install-NetBirdTask {
    if ($Uninstall) {
        Write-Error "Cannot use -Install and -Uninstall together."
        exit 1
    }

    Write-Host "=== Installing NetBird delayed auto update task ==="

    # Determine path to this script
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }

    if (-not (Test-Path $scriptPath)) {
        Write-Error "Cannot determine script path. Aborting."
        exit 1
    }

    # Parse DailyTime (HH:mm)
    try {
        $timeSpan = [TimeSpan]::Parse($DailyTime)
    }
    catch {
        Write-Error "Invalid DailyTime format: '$DailyTime'. Use HH:mm, e.g. '03:30'."
        exit 1
    }

    $startTime = (Get-Date).Date + $timeSpan

    # Prepare arguments for powershell.exe
    $escapedScriptPath = $scriptPath.Replace('"', '\"')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScriptPath`" -DelayDays $DelayDays -MaxRandomDelaySeconds $MaxRandomDelaySeconds"

    Write-Host "Script path: $scriptPath"
    Write-Host "DelayDays: $DelayDays"
    Write-Host "MaxRandomDelaySeconds: $MaxRandomDelaySeconds"
    Write-Host "Daily time: $DailyTime"

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

    # Remove existing task if present
    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Existing task '$TaskName' found. Removing..."
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
    catch {
        Write-Warning "Failed to check/remove existing task: $($_.Exception.Message)"
    }

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal | Out-Null

    Write-Host "Task '$TaskName' has been created successfully."
    Write-Host "Done."
}

# ------------------ MODE: UNINSTALL TASK ------------------

function Uninstall-NetBirdTask {
    Write-Host "=== Uninstalling NetBird delayed auto update task ==="

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Task '$TaskName' has been removed."
        }
        else {
            Write-Host "Task '$TaskName' not found."
        }
    }
    catch {
        Write-Warning "Failed to remove task '$TaskName': $($_.Exception.Message)"
    }

    if ($RemoveState) {
        $stateDir = $StateDir
        if (Test-Path $stateDir) {
            try {
                Remove-Item -Path $stateDir -Recurse -Force
                Write-Host "State and log directory '$stateDir' has been removed."
            }
            catch {
                Write-Warning "Failed to remove '$stateDir': $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "Directory '$stateDir' not found, skipping."
        }
    }

    Write-Host "Done."
}

# ------------------ MODE: RUN (DELAYED UPDATE LOGIC) ------------------

function Invoke-NetBirdDelayedUpdate {
    $exitCode = 0

    Ensure-StateDir

    Write-Log "=== NetBird delayed update started, DelayDays=$DelayDays, MaxRandomDelaySeconds=$MaxRandomDelaySeconds ==="

    # Random delay
    if ($MaxRandomDelaySeconds -gt 0) {
        $sleepSeconds = Get-Random -Minimum 0 -Maximum ($MaxRandomDelaySeconds + 1)
        Write-Log "Random delay before check: $sleepSeconds seconds."
        Start-Sleep -Seconds $sleepSeconds
    }

    # Check that choco exists
    $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $chocoCmd) {
        Write-Log "ERROR: Chocolatey (choco.exe) is not available in PATH. Exiting."
        return 1
    }

    # Get installed version
    $installedVersionString = Get-ChocoVersionString -Name $PackageName -Local
    if (-not $installedVersionString) {
        Write-Log "Package '$PackageName' is not installed locally. No auto-install, exiting."
        return 0
    }

    Write-Log "Installed $PackageName version: $installedVersionString"

    # Get repository version
    $candidateVersionString = Get-ChocoVersionString -Name $PackageName
    if (-not $candidateVersionString) {
        Write-Log "WARNING: No repository version for '$PackageName' found in Chocolatey. Exiting."
        return 0
    }

    Write-Log "Repository candidate version for ${PackageName}: $candidateVersionString"

    # Parse versions
    try {
        $installedVersion = [version]$installedVersionString
        $candidateVersion = [version]$candidateVersionString
    }
    catch {
        Write-Log "ERROR: Failed to parse versions. Installed='$installedVersionString', Repo='$candidateVersionString'."
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

    $ageDays = ($nowUtc - $firstSeenUtc).TotalDays
    Write-Log ("Candidate version age: {0:N2} days (required: {1})" -f $ageDays, $DelayDays)

    if ($ageDays -lt $DelayDays) {
        Write-Log "Too early to update. Waiting for candidate to age enough."
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
        Write-Log "WARNING: Failed to stop NetBird service: $($_.Exception.Message)"
    }

    # Run choco upgrade
    Write-Log "Running: choco upgrade $PackageName -y --no-progress"
    & choco upgrade $PackageName -y --no-progress
    $exitCode = $LASTEXITCODE
    Write-Log "choco upgrade exited with code $exitCode"

    # Try to restart NetBird service
    try {
        $svc = Get-Service -Name Netbird -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Write-Log "Starting NetBird service..."
            Start-Service -Name Netbird -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            $svc.Refresh()
            Write-Log "NetBird service status after start: $($svc.Status)"
        }
        else {
            Write-Log "NetBird service is already running or not found."
        }
    }
    catch {
        Write-Log "WARNING: Failed to start NetBird service: $($_.Exception.Message)"
    }

    # Save updated state
    Save-State -CandidateVersion $candidateVersionString -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc

    Write-Log "=== NetBird delayed update finished ==="
    return $exitCode
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

# Default: run update logic once
$code = Invoke-NetBirdDelayedUpdate
exit $code
