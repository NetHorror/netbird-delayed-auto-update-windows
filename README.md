# NetBird Delayed Auto-Update for Windows (Chocolatey)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: Windows](https://img.shields.io/badge/platform-Windows-informational) ![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-brightgreen) ![Package manager: Chocolatey](https://img.shields.io/badge/package%20manager-Chocolatey-8A4513)

PowerShell script that implements *delayed / staged* updates for the NetBird Windows client installed via Chocolatey.

Instead of upgrading to the latest Chocolatey version immediately, new versions must “age” for a configurable number of days before they are allowed to be installed. Short-lived or bad releases that get quickly replaced will never reach your machines.

The script can also:

- auto-update the **NetBird GUI** from the official installer feed;
- **self-update** based on GitHub releases of this repo;
- keep its own log files under control with configurable log retention.

> Tested with NetBird installed from the Chocolatey package `netbird`.

---

## Features

- **Delayed rollout for NetBird (Chocolatey)**
  - New package versions must exist in the Chocolatey feed for at least `DelayDays` days before upgrade.
  - Age is tracked per candidate version in a local `state.json` file.
- **Randomized scheduling**
  - Optional random delay before each run via `MaxRandomDelaySeconds` to avoid thundering-herd upgrades.
- **NetBird GUI auto-update**
  - Detects the latest NetBird version from GitHub releases.
  - Downloads the latest Windows x64 GUI installer from `https://pkgs.netbird.io/windows/x64`.
  - Installs it silently (`/S`).
  - Tracks last installed GUI version in `gui-state.json` to avoid re-installing the same version.
  - GUI is only updated when the daemon was actually upgraded during the current run.
- **Script self-update**
  - Compares the local `$ScriptVersion` with the latest GitHub release tag of this repo.
  - Uses `git pull` when inside a git repo, otherwise downloads the script from the tagged version on GitHub.
- **Log retention**
  - Logs to date-stamped files under `C:\ProgramData\NetBirdDelayedUpdate`.
  - Old log files are automatically deleted based on `LogRetentionDays` (default: 60 days).
- **System-friendly**
  - Uses the existing NetBird Chocolatey package.
  - Works well as a scheduled task (SYSTEM or current user with highest privileges).

---

## Requirements

- Windows with PowerShell (Windows PowerShell 5.1 or PowerShell 7+).
- [Chocolatey](https://chocolatey.org/) installed.
- NetBird installed via Chocolatey (default package name: `netbird`).

---

## Installation & usage

### 1. Download the script

Copy `netbird-delayed-update.ps1` from this repository to a directory on the target machine, for example:

~~~text
C:\Windows\System32\netbird-delayed-auto-update-windows\netbird-delayed-update.ps1
~~~

Make sure the directory is readable and the script is executable by the account that will be running the scheduled task.

---

### 2. One-off manual run (for testing)

You can run the script manually to test the logic without waiting for the scheduled task:

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 `
  -DelayDays 0 `
  -MaxRandomDelaySeconds 0
~~~

This will:

1. Check the installed NetBird version via Chocolatey.
2. Check the candidate version from the Chocolatey feed.
3. Decide whether an upgrade is needed (taking `DelayDays` into account).
4. If an upgrade was performed, try to restart the NetBird service.
5. If the daemon was upgraded, optionally update the NetBird GUI.
6. Clean up old log files according to `LogRetentionDays`.

---

### 3. Install the scheduled task

To install a daily scheduled task (recommended):

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 `
  -Install `
  -DelayDays 10 `
  -MaxRandomDelaySeconds 3600 `
  -LogRetentionDays 60 `
  -StartWhenAvailable
~~~

This will:

- create (or update) a scheduled task named **"NetBird Delayed Choco Update"**;
- schedule it to run daily at `04:00` by default;
- run with **SYSTEM** privileges by default;
- call the script in **Run mode** with the given parameters.

#### Run task as the current user

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

---

### 4. Uninstall the scheduled task

To remove the scheduled task:

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 -Uninstall
~~~

To also remove state and logs (`C:\ProgramData\NetBirdDelayedUpdate`):

~~~powershell
powershell -ExecutionPolicy Bypass -File .\netbird-delayed-update.ps1 -Uninstall -RemoveState
~~~

---

## Behaviour details

### Delayed rollout (Chocolatey)

The script keeps a simple JSON state file:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\state.json
~~~

It stores:

- the current **candidate version** from Chocolatey;
- when this candidate was **first seen** (`FirstSeenUtc`);
- when the last check occurred.

On each run:

1. It queries the installed NetBird version via:

   - `choco list netbird --localonly --exact --limit-output`

2. It queries the candidate version in the repo via:

   - `choco search netbird --exact --limit-output`

3. It compares the candidate version with the currently installed version.
4. If the candidate is **newer**:
   - it calculates how long this version has been in the repo based on `FirstSeenUtc`;
   - the age is **clamped to at least 0 days** to avoid negative values from clock skew;
   - only if `ageDays >= DelayDays` will the script run:

     - `choco upgrade netbird -y --no-progress`

5. If no upgrade is needed, the state file is updated with the latest check time.

If the NetBird package is **not installed locally**, the script logs this and exits with code `0`.

---

### NetBird GUI auto-update

If the NetBird daemon was successfully upgraded during this run, the script:

1. Queries the latest NetBird release from GitHub:

   - `https://api.github.com/repos/netbirdio/netbird/releases/latest`

2. Parses the tag name (`vX.Y.Z` or `X.Y.Z`) into a plain version string like `0.60.7`.
3. Checks the GUI state file:

   ~~~text
   C:\ProgramData\NetBirdDelayedUpdate\gui-state.json
   ~~~

   - if `LastGuiVersion` equals the latest version → GUI update is skipped.

4. If the GUI is out of date:
   - downloads the latest x64 installer from:

     ~~~text
     https://pkgs.netbird.io/windows/x64
     ~~~

   - runs it silently with `/S`;
   - updates `gui-state.json` with the new GUI version and timestamp.

The GUI installer is **not** invoked if:

- the NetBird package is not installed, or
- the daemon version did not change in this run.

---

### Script self-update

The script can optionally update itself based on GitHub releases of this repo.

On each run (before doing anything else) it:

1. Checks the latest release of `NetHorror/netbird-delayed-auto-update-windows` via GitHub API.
2. Compares its tag (e.g. `0.2.1`) with the local `$ScriptVersion`.
3. If the remote version is **newer**:
   - tries to find a `.git` repo above the script path and run:

     ~~~powershell
     git -C <repoRoot> pull --ff-only
     ~~~

   - if that fails or `git` is not available:
     - downloads `netbird-delayed-update.ps1` from:

       ~~~text
       https://raw.githubusercontent.com/NetHorror/netbird-delayed-auto-update-windows/<tag>/netbird-delayed-update.ps1
       ~~~

     - overwrites the local script.

The updated script is used on the **next** run.

To disable self-update, you can:

- set `$ScriptRepo = ""` in the script, or
- comment out the `Invoke-SelfUpdateByRelease` call at the bottom.

---

## Logs and state

All runtime files live under:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\
~~~

- `state.json` – delayed rollout state for the daemon (candidate version, first seen, last check).
- `gui-state.json` – last installed GUI version and last update time.
- `netbird-delayed-update-*.log` – per-run logs; old files are cleaned up according to `LogRetentionDays`.

By default, log files older than **60 days** are removed automatically.

---

## Versioning & changelog

This project uses semantic versioning:

- `0.2.1` – current stable (log retention, safe age, smarter GUI).
- `0.2.0` – GUI auto-update, script self-update, default `DelayDays = 10`.

See [`CHANGELOG.md`](./CHANGELOG.md) for a full list of changes.
