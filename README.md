# NetBird Delayed Auto-Update for Windows (Chocolatey)

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE) ![Platform: Windows](https://img.shields.io/badge/platform-Windows-informational) ![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-brightgreen) ![Package manager: Chocolatey](https://img.shields.io/badge/package%20manager-Chocolatey-8A4513)
# NetBird Delayed Auto-Update for Windows (Chocolatey)

PowerShell script that implements delayed / staged updates for the NetBird Windows client installed via Chocolatey.
Instead of upgrading to the latest Chocolatey version immediately, new versions must “age” for a configurable number of days before they are allowed to be installed. Short-lived or bad releases that get quickly replaced will never reach your machines.

* * *

## Quick start

### Option A: git clone (recommended)

Clone the repository:

~~~bash
git clone https://github.com/NetHorror/netbird-delayed-auto-update-windows.git
cd netbird-delayed-auto-update-windows
~~~

### Option B: download a single file

Download `netbird-delayed-update.ps1` from this repository and place it in a stable path, for example:

~~~text
C:\Windows\System32\netbird-delayed-auto-update-windows\netbird-delayed-update.ps1
~~~

> Tip: keep the script in a fixed path. Scheduled Task stores the full script path.

### One-off manual run (for testing)

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 `
  -DelayDays 0 `
  -MaxRandomDelaySeconds 0
~~~

### Install the scheduled task (recommended)

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 `
  -Install `
  -DelayDays 10 `
  -MaxRandomDelaySeconds 3600 `
  -LogRetentionDays 60 `
  -StartWhenAvailable
~~~

* * *

## Features

- Delayed rollout for NetBird (Chocolatey)
  - New package versions must exist in the Chocolatey feed for at least `DelayDays` days before upgrade.
  - Age is tracked per candidate version in a local `state.json` file.
- Randomized scheduling
  - Optional random delay before each run via `MaxRandomDelaySeconds` to avoid thundering-herd upgrades.
- NetBird GUI auto-update
  - Detects the latest NetBird version from GitHub releases.
  - Downloads the latest Windows x64 GUI installer from `https://pkgs.netbird.io/windows/x64`.
  - Installs it silently (`/S`).
  - Tracks last installed GUI version in `gui-state.json` to avoid re-installing the same version.
  - GUI is only updated when the daemon was actually upgraded during the current run.
- Script self-update
  - Compares the local `$ScriptVersion` with the latest GitHub release tag of this repo.
  - Uses `git pull` when inside a git repo, otherwise downloads the script from the tagged version on GitHub.
- Log retention
  - Logs to date-stamped files under `C:\ProgramData\NetBirdDelayedUpdate`.
  - Old log files are automatically deleted based on `LogRetentionDays` (default: 60 days).
- Reliability improvements (0.2.2)
  - Scheduled Task uses `-NoProfile` for predictable execution.
  - GitHub API calls include a User-Agent header and enforce TLS 1.2 for compatibility.
  - GUI installer exit code is validated; GUI state is not updated on failure.
  - More robust parsing of stored timestamps and better service name detection.

* * *

## Requirements

- Windows with PowerShell (Windows PowerShell 5.1 or PowerShell 7+).
- [Chocolatey](https://chocolatey.org) installed.
- NetBird installed via Chocolatey (default package name: `netbird`).

* * *

## Installing Chocolatey

Chocolatey is required because the script upgrades NetBird using `choco upgrade`.

### Install via PowerShell (recommended)

Run PowerShell **as Administrator**:

~~~powershell
Set-ExecutionPolicy Bypass -Scope Process -Force;
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
~~~

Verify:

~~~powershell
choco -v
~~~

### Install via CMD

Run **Command Prompt as Administrator**:

~~~cmd
@"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -InputFormat None -ExecutionPolicy Bypass -Command "[System.Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))" && SET "PATH=%PATH%;%ALLUSERSPROFILE%\chocolatey\bin"
~~~

Verify:

~~~cmd
choco -v
~~~

* * *

## Parameters

The script supports three modes:

- **Run mode (default)**: run the delayed update check and (if allowed) upgrade NetBird via Chocolatey.
- **Install mode**: create/update a Scheduled Task that runs the script daily.
- **Uninstall mode**: remove the Scheduled Task (optionally delete logs/state).

### Modes

- `-Install` (`-i`)
  - Installs or updates the Scheduled Task.
  - Example:
    ~~~powershell
    powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 -Install
    ~~~

- `-Uninstall` (`-u`)
  - Removes the Scheduled Task.
  - Example:
    ~~~powershell
    powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 -Uninstall
    ~~~

- `-RemoveState`
  - Only meaningful with `-Uninstall`.
  - Also deletes `C:\ProgramData\NetBirdDelayedUpdate` (logs + state).
  - Example:
    ~~~powershell
    powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 -Uninstall -RemoveState
    ~~~

### Scheduling (only used with `-Install`)

- `-DailyTime <HH:mm>`
  - Time of day for the Scheduled Task trigger (24h format).
  - Default: `04:00`

- `-TaskName <string>`
  - Scheduled Task name.
  - Default: `NetBird Delayed Choco Update`

- `-StartWhenAvailable` (`-r`)
  - If a scheduled run was missed (PC was off), run ASAP after boot.

- `-RunAsCurrentUser`
  - If set, the task will run as the current user with highest privileges.
  - If not set, the task runs as **SYSTEM** (recommended).

> Note: values you pass during `-Install` are embedded into the task command line.
> To change them later, run `-Install` again with new values.

### Update logic (Run mode and also embedded into task on Install)

- `-DelayDays <int>`
  - Minimum “aging” time (days) a new Chocolatey version must be visible before upgrade is allowed.
  - Default: `10`
  - `0` disables delay (upgrade immediately).

- `-MaxRandomDelaySeconds <int>`
  - Adds a random sleep before the version check to reduce simultaneous upgrades across machines.
  - Default: `3600` (1 hour)
  - `0` disables random delay.

- `-PackageName <string>`
  - Chocolatey package name to manage.
  - Default: `netbird`

### Logs / retention

- `-LogRetentionDays <int>`
  - How many days to keep log files under `C:\ProgramData\NetBirdDelayedUpdate`.
  - Default: `60`
  - `0` (or negative) disables log cleanup.

* * *

## Installation & usage

### Run task as the current user (optional)

If you prefer the task to run as the current user (with highest privileges):

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 `
  -Install `
  -DelayDays 10 `
  -MaxRandomDelaySeconds 3600 `
  -LogRetentionDays 60 `
  -StartWhenAvailable `
  -RunAsCurrentUser
~~~

### Uninstall the scheduled task

To remove the scheduled task:

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 -Uninstall
~~~

To also remove state and logs (`C:\ProgramData\NetBirdDelayedUpdate`):

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 -Uninstall -RemoveState
~~~

* * *

## Behaviour details

### Delayed rollout (Chocolatey)

The script keeps a simple JSON state file:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\state.json
~~~

It stores:

- the current candidate version from Chocolatey;
- when this candidate was first seen (`FirstSeenUtc`);
- when the last check occurred.

On each run:

1. It queries the installed NetBird version via:
   - `choco list netbird --localonly --exact --limit-output`
2. It queries the candidate version in the repo via:
   - `choco search netbird --exact --limit-output`
3. It compares the candidate version with the currently installed version.
4. If the candidate is newer:
   - it computes how long it has been “in the feed” based on `FirstSeenUtc`;
   - clamps negative values to `0` (clock skew safety);
   - if `ageDays >= DelayDays`, it runs:
     - `choco upgrade netbird -y --no-progress`
5. If NetBird is not installed locally, the script logs this and exits with code `0`.

### NetBird GUI auto-update

If the NetBird daemon was successfully upgraded during this run, the script can:

1. Query the latest NetBird release from GitHub releases.
2. If GUI is out of date (tracked in `gui-state.json`):
   - download the latest x64 installer from:
     - `https://pkgs.netbird.io/windows/x64`
   - run it silently (`/S`);
   - update `gui-state.json` with the new GUI version and timestamp.

GUI installer is not invoked if:
- NetBird package is not installed, or
- daemon version did not change in this run.

### Script self-update

On each run (before doing anything else) it:
1. Checks the latest release of this repo via GitHub API.
2. Compares its tag (e.g. `0.2.2`) with the local `$ScriptVersion`.
3. If remote version is newer:
   - tries `git pull --ff-only` when inside a git checkout, otherwise
   - downloads `netbird-delayed-update.ps1` from the tagged version and overwrites the local script.

The updated script is used on the next run.

* * *

## Example timeline

Assumptions:
- `DelayDays = 10`
- scheduled run once per day

Day 0:
- Chocolatey feed publishes NetBird `0.60.0`
- Script detects new candidate `0.60.0`, records `FirstSeenUtc`, does **not** upgrade yet.

Day 3:
- `0.60.0` gets replaced by `0.60.1`
- Script detects candidate change, resets the aging window for `0.60.1`.

Day 11 (since first seeing `0.60.1`):
- Candidate `0.60.1` has aged long enough
- Script upgrades NetBird via Chocolatey
- GUI installer runs (if enabled/needed)

If a “bad” version appears and is replaced before it’s old enough, clients will never upgrade to it.

* * *

## Logs and state

All runtime files live under:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\
~~~

- `state.json` – delayed rollout state for the daemon (candidate version, first seen, last check).
- `gui-state.json` – last installed GUI version and last update time.
- `netbird-delayed-update-*.log` – per-run logs; old files are cleaned up according to `LogRetentionDays`.

* * *

## Versioning & changelog

This project uses semantic versioning.

See `CHANGELOG.md` for a full list of changes.

* * *

## Related projects

- Linux (APT + systemd): `NetHorror/netbird-delayed-auto-update-linux`
- macOS (launchd): `NetHorror/netbird-delayed-auto-update-macos`

* * *

## License

MIT License (see `LICENSE`).

