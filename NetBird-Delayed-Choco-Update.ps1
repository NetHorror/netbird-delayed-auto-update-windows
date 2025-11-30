param(
    [int]$DelayDays = 3,                     # how many days a candidate version must "age"
    [int]$MaxRandomDelaySeconds = 3600,      # random startup delay in seconds (0..N)
    [string]$PackageName = "netbird"         # Chocolatey package name
)

# ------------------ SETTINGS ------------------
$StateDir  = "C:\ProgramData\NetBirdDelayedUpdate"
$StateFile = Join-Path $StateDir "state.json"
$LogDir    = $StateDir
$LogFile   = Join-Path $LogDir ("netbird-delayed-update-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

# ------------------ HELPER FUNCTIONS ------------------

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    $line | Tee-Object -FilePath $LogFile -Append | Out-Null
}

function Get-ChocoVersionInfo {
    param(
        [string]$Name,
        [switch]$Local
    )

    $args = @()

    if ($Local) {
        # query local installed package
        $args += "list"
        $args += $Name
        $args += "--local-only"
    } else {
        # query remote repository
        $args += "search"
        $args += $Name
    }

    # -r / --limit-output => "name|version"
    # -e / --exact
    $args += @(
        "-r",
        "-e"
    )

    try {
        $output = choco @args 2>$null | Select-Object -First 1
        if (-not $output) { return $null }

        $parts = $output -split '\|'
        if ($parts.Count -lt 2) { return $null }

        return [PSCustomObject]@{
            Name    = $parts[0]
            Version = $parts[1]
        }
    }
    catch {
        Write-Log "ERROR: Failed to query Chocolatey package '$Name': $($_.Exception.Message)"
        return $null
    }
}

function Load-State {
    if (Test-Path $StateFile) {
        try {
            $json = Get-Content $StateFile -Raw
            if ($json -and $json.Trim().Length -gt 0) {
                return $json | ConvertFrom-Json
            }
        }
        catch {
            Write-Log "WARNING: Failed to read state.json: $($_.Exception.Message). It will be reinitialized."
        }
    }
    return $null
}

function Save-State {
    param(
        [string]$CandidateVersion,
        [datetime]$FirstSeenUtc,
        [datetime]$LastCheckUtc
    )

    $state = [PSCustomObject]@{
        CandidateVersion = $CandidateVersion
        FirstSeenUtc     = $FirstSeenUtc.ToUniversalTime().ToString("o")
        LastCheckUtc     = $LastCheckUtc.ToUniversalTime().ToString("o")
    }

    try {
        $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    }
    catch {
        Write-Log "ERROR: Failed to save state.json: $($_.Exception.Message)"
    }
}

# ------------------ MAIN SCRIPT ------------------

Write-Log "=== NetBird delayed update started, DelayDays=$DelayDays, MaxRandomDelaySeconds=$MaxRandomDelaySeconds ==="

# 1. Random startup delay to avoid thundering herd on the repository
if ($MaxRandomDelaySeconds -gt 0) {
    $delay = Get-Random -Minimum 0 -Maximum $MaxRandomDelaySeconds
    Write-Log "Random delay before check: $delay seconds."
    Start-Sleep -Seconds $delay
}

# 2. Ensure Chocolatey is available
if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Write-Log "ERROR: Chocolatey (choco.exe) is not available in PATH. Aborting."
    exit 1
}

# 3. Check if NetBird is installed locally
$localInfo = Get-ChocoVersionInfo -Name $PackageName -Local
if (-not $localInfo) {
    Write-Log "INFO: Package '$PackageName' is not installed locally. No auto-install, exiting."
    exit 0
}

$installedVersion = $localInfo.Version
Write-Log "Installed $PackageName version: $installedVersion"

# 4. Get candidate version from Chocolatey repository
$remoteInfo = Get-ChocoVersionInfo -Name $PackageName
if (-not $remoteInfo) {
    Write-Log "ERROR: Failed to get candidate version of '$PackageName' from Chocolatey. Aborting."
    exit 1
}

$candidateVersion = $remoteInfo.Version
Write-Log "Repository candidate version for ${PackageName}: $candidateVersion"

# 5. Load state
$state  = Load-State
$nowUtc = (Get-Date).ToUniversalTime()

if (-not $state -or -not $state.CandidateVersion) {
    # No previous state: record first time we see this version
    Write-Log "State is not initialized. Recording candidate version $candidateVersion and starting aging timer."
    Save-State -CandidateVersion $candidateVersion -FirstSeenUtc $nowUtc -LastCheckUtc $nowUtc
    exit 0
}

if ($state.CandidateVersion -ne $candidateVersion) {
    # Repository version changed: reset aging timer
    Write-Log "New candidate version detected: $candidateVersion (previous: $($state.CandidateVersion)). Resetting aging timer."
    Save-State -CandidateVersion $candidateVersion -FirstSeenUtc $nowUtc -LastCheckUtc $nowUtc
    exit 0
}

# 6. Same candidate version, compute "age"
try {
    $firstSeenUtc = [datetime]::Parse($state.FirstSeenUtc).ToUniversalTime()
}
catch {
    Write-Log "WARNING: Failed to parse FirstSeenUtc in state.json, reinitializing state."
    Save-State -CandidateVersion $candidateVersion -FirstSeenUtc $nowUtc -LastCheckUtc $nowUtc
    exit 0
}

$age     = $nowUtc - $firstSeenUtc
$ageDays = [math]::Floor($age.TotalDays)

Write-Log "Candidate version $candidateVersion has been observed for $ageDays days (minimum required: $DelayDays days)."

if ($age.TotalDays -lt $DelayDays) {
    Write-Log "Too early to update. Waiting for the version to age."
    Save-State -CandidateVersion $candidateVersion -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc
    exit 0
}

# 7. Version is old enough – check if there is anything to upgrade
if ($installedVersion -eq $candidateVersion) {
    Write-Log "NetBird is already at version $installedVersion. No update required."
    Save-State -CandidateVersion $candidateVersion -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc
    exit 0
}

Write-Log "Version aged enough and upgrade is required: $installedVersion -> $candidateVersion."

# 8. Try to stop NetBird service (if present)
try {
    $svc = Get-Service -Name Netbird -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Log "Stopping NetBird service..."
        Stop-Service -Name Netbird -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    } else {
        Write-Log "NetBird service is not running or not found. Skipping stop."
    }
}
catch {
    Write-Log "WARNING: Failed to stop NetBird service: $($_.Exception.Message)"
}

# 9. Run upgrade via Chocolatey
Write-Log "Running: choco upgrade $PackageName -y --no-progress"
choco upgrade $PackageName -y --no-progress
$exitCode = $LASTEXITCODE
Write-Log "choco upgrade exited with code $exitCode"

# 10. Try to restart NetBird service
try {
    $svc = Get-Service -Name Netbird -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-Log "Starting NetBird service..."
        Start-Service -Name Netbird -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        $svc.Refresh()
        Write-Log "NetBird service status after start: $($svc.Status)"
    } else {
        Write-Log "NetBird service is already running or not found."
    }
}
catch {
    Write-Log "WARNING: Failed to start NetBird service: $($_.Exception.Message)"
}

# 11. Save updated state
Save-State -CandidateVersion $candidateVersion -FirstSeenUtc $firstSeenUtc -LastCheckUtc $nowUtc

Write-Log "=== NetBird delayed update finished ==="
exit $exitCode
