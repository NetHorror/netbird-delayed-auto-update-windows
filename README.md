# NetBird Delayed Auto-Update for Windows (Chocolatey)

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE) ![Platform: Windows](https://img.shields.io/badge/platform-Windows-informational) ![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-brightgreen) ![Package manager: Chocolatey](https://img.shields.io/badge/package%20manager-Chocolatey-8A4513)

PowerShell script that implements delayed / staged updates for the NetBird Windows client installed via Chocolatey.
Instead of upgrading to the latest Chocolatey version immediately, new versions must “age” for a configurable number of days before they are allowed to be installed. Short-lived or bad releases that get quickly replaced will never reach your machines.

* * *

## Quick start

### 1. Install

~~~powershell
irm https://github.com/NetHorror/netbird-delayed-auto-update-windows/releases/download/0.3.0/install.ps1 | iex
~~~

The install command:

1. downloads the script and `SHA256SUMS` from the release and checks the SHA-256 hash (it stops on a mismatch);
2. installs NetBird if it is missing (`-InstallClient`): with Chocolatey if it is present, otherwise the official installer after an Authenticode check (`CN=NetBird GmbH`);
3. creates a daily Scheduled Task (04:00) that runs as SYSTEM.

Keep the script in `C:\ProgramData\NetBirdDelayedUpdate\bin`: the Scheduled Task stores its path.

> **The first install takes the current latest NetBird version.** The delay (`-DelayDays`, 10 days by default) applies only to later updates, and only for Chocolatey installs.

### 2. Check

~~~powershell
Get-ScheduledTask -TaskName "NetBird Delayed Choco Update"
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\NetBirdDelayedUpdate\bin\netbird-delayed-update.ps1" -DelayDays 0 -MaxRandomDelaySeconds 0
~~~

The second command is a one-off run without delay. Logs: see [Logs and state](#logs-and-state).

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
- NetBird client installation
  - If NetBird is missing, asks in an interactive session (or installs right away with `-InstallClient`).
  - Uses `choco install netbird` when Chocolatey is present, otherwise the signed official installer.
- Script self-update
  - Compares the local `$ScriptVersion` with the latest GitHub release tag of this repo.
  - Downloads the script from the release assets and verifies it against `SHA256SUMS` (disable with `-NoSelfUpdate`).
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
- NetBird installed via Chocolatey (default package name: `netbird`) — or let the script install it (`-InstallClient`).

> **Delayed daemon updates work only for Chocolatey installs.** If Chocolatey is not present,
> `-InstallClient` falls back to the official installer from `pkgs.netbird.io`; NetBird will be
> installed, but the script cannot apply delayed updates to it later (they are done only via `choco`).

* * *

## Installing Chocolatey

Chocolatey installs NetBird and upgrades it with `choco upgrade --version`. Run PowerShell **as Administrator**:

~~~powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
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

### Client installation / self-update

- `-InstallClient`
  - If NetBird is not found (service `netbird`, `C:\Program Files\NetBird\netbird.exe` or the Chocolatey package),
    install it without asking. Works in Run mode and together with `-Install`.
  - With Chocolatey: `choco install netbird -y --no-progress`. Without it: the official installer
    `https://pkgs.netbird.io/windows/x64`, run with `/S` only if its Authenticode signature is `Valid`
    and issued to `CN=NetBird GmbH`.
  - **The first installation installs the current latest NetBird version** — `DelayDays` applies only to later updates.
  - Without `-InstallClient`: an interactive session asks `Install now? [Y/n]`; a non-interactive run
    (Scheduled Task, SYSTEM, `-NonInteractive`, redirected input) logs a WARN and exits with code `0`.

- `-NoSelfUpdate`
  - Disables the script self-update. Self-update is enabled by default.
  - When passed with `-Install`, it is embedded into the Scheduled Task command line.

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

## Uninstall

Remove the Scheduled Task:

~~~powershell
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\NetBirdDelayedUpdate\bin\netbird-delayed-update.ps1" -Uninstall
~~~

Also delete logs and state (`C:\ProgramData\NetBirdDelayedUpdate`):

~~~powershell
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\NetBirdDelayedUpdate\bin\netbird-delayed-update.ps1" -Uninstall -RemoveState
~~~

To run the task as the current user instead of SYSTEM, add `-RunAsCurrentUser` to the install command (see [Parameters](#parameters)).

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
     - `choco upgrade netbird --version <candidate> -y --no-progress`
5. If NetBird is not installed at all, see `-InstallClient` (non-interactive runs log a WARN and exit with code `0`).
   If it is installed but not via Chocolatey, the script logs this and exits with code `0`.

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

On each run (before doing anything else, unless `-NoSelfUpdate` is set) it:
1. Reads `tag_name` of the latest release of this repo via the GitHub API
   (`X.Y.Z` or `vX.Y.Z`; anything else is ignored).
2. Continues only if that version is newer than the local `$ScriptVersion`.
3. Takes the `netbird-delayed-update.ps1` and `SHA256SUMS` release assets (if either is missing — logs and changes nothing)
   and downloads both to temporary files next to the script.
4. Requires the SHA256 of the downloaded script to match its line in `SHA256SUMS` and the file to contain
   `$ScriptVersion = "<version>"`; otherwise logs an ERROR and changes nothing.
5. Backs up the current script to `<script>.bak-<timestamp>`, copies its ACL onto the new file and replaces
   it with an atomic `Move-Item`.

`git pull` is no longer used. The updated script is used on the next run.

**Releases must therefore include two assets:** `netbird-delayed-update.ps1` and `SHA256SUMS`
(`sha256sum`-style line: `<hex>  netbird-delayed-update.ps1`). Versions 0.2.x still update themselves
from the raw file at the release tag, so the `$ScriptVersion = "X.Y.Z"` line must keep its format.

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

