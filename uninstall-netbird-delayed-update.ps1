param(
    [string]$TaskName = "NetBird Delayed Choco Update",
    [switch]$RemoveState
)

Write-Host "=== Uninstalling NetBird delayed auto update task ==="

try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Task '$TaskName' has been removed."
    } else {
        Write-Host "Task '$TaskName' not found."
    }
}
catch {
    Write-Warning "Failed to remove task '$TaskName': $($_.Exception.Message)"
}

if ($RemoveState.IsPresent) {
    $stateDir = "C:\ProgramData\NetBirdDelayedUpdate"
    if (Test-Path $stateDir) {
        try {
            Remove-Item -Path $stateDir -Recurse -Force
            Write-Host "State and log directory '$stateDir' has been removed."
        }
        catch {
            Write-Warning "Failed to remove '$stateDir': $($_.Exception.Message)"
        }
    } else {
        Write-Host "Directory '$stateDir' not found, skipping."
    }
}

Write-Host "Done."
