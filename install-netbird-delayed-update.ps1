param(
    [int]$DelayDays = 3,
    [int]$MaxRandomDelaySeconds = 3600,
    [string]$DailyTime = "04:00",
    [string]$TaskName = "NetBird Delayed Choco Update",
    [switch]$RunAsCurrentUser  # otherwise run as SYSTEM
)

Write-Host "=== Installing NetBird delayed auto update task ==="

# Path to main script inside the repository
$scriptPath = Join-Path $PSScriptRoot "NetBird-Delayed-Choco-Update.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Error "Script not found: $scriptPath. Make sure you run this installer from the repository folder."
    exit 1
}

# Parse DailyTime (HH:mm) into a TimeSpan
try {
    $time = [TimeSpan]::Parse($DailyTime)
}
catch {
    Write-Error "Invalid DailyTime format: '$DailyTime'. Use HH:mm, e.g. '03:30'."
    exit 1
}

# Prepare arguments for powershell.exe
$escapedScriptPath = $scriptPath.Replace('"', '\"')
$arguments = "-ExecutionPolicy Bypass -File `"$escapedScriptPath`" -DelayDays $DelayDays -MaxRandomDelaySeconds $MaxRandomDelaySeconds"

Write-Host "Script path: $scriptPath"
Write-Host "Task name:   $TaskName"
Write-Host "Daily time:  $DailyTime"
Write-Host "DelayDays:   $DelayDays"
Write-Host "MaxRandomDelaySeconds: $MaxRandomDelaySeconds"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments

# Compute first run time for today; the scheduler will take care of daily execution
$runTime = [datetime]::Today.Add($time)
$trigger = New-ScheduledTaskTrigger -Daily -At $runTime

if ($RunAsCurrentUser.IsPresent) {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    Write-Host "The task will run as current user: $user (with highest privileges)."
    $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest
} else {
    Write-Host "The task will run as SYSTEM (with highest privileges)."
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
}

# If task already exists – remove it
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
