# NetBird Delayed Auto-Update for Windows (Chocolatey)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: Windows](https://img.shields.io/badge/platform-Windows-informational) ![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-brightgreen) ![Package manager: Chocolatey](https://img.shields.io/badge/package%20manager-Chocolatey-8A4513)

> Delayed (staged) auto-update for the NetBird client on Windows (Server 2019+ / Windows 10+).

- Do **not** upgrade NetBird immediately when a new version appears in Chocolatey.
- Wait `DelayDays` days. If that version is quickly replaced (hotfix / bad release), clients will never see it.
- When the version has “aged” enough, the script:
  - upgrades the **NetBird daemon** via Chocolatey;
  - updates the **NetBird GUI** via the official Windows installer;
  - can optionally **update the script itself** from GitHub releases.

---

## Idea

- A candidate NetBird version in the Chocolatey repository must “age” for `DelayDays` days before it is allowed to be installed.
- If the same version stays in the repo for `DelayDays` without changes, the installed client is upgraded.
- If a newer version appears, the aging timer is reset and the counter starts from zero again.
- NetBird is **not auto-installed** – only upgraded if it is already installed via Chocolatey.
- A Windows Task Scheduler task runs a single PowerShell script once per day.
- State and logs are stored in:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\
~~~

- `state.json` – aging state for the daemon (Chocolatey side).
- `gui-state.json` – last GUI version installed by the script.
- `netbird-delayed-update-*.log` – detailed logs for each run.

---

## Features

- ⏳ **Version aging**  
  Only upgrades NetBird after a candidate version has been present in Chocolatey for at least `DelayDays`.

- 📦 **Daemon update via Chocolatey**  
  Uses `choco upgrade netbird` (or another package if `-PackageName` is overridden) after the aging period.

- 🖥️ **GUI auto-update** (since `0.2.0`)  
  - Reads the latest NetBird release version from GitHub.
  - Downloads the latest Windows x64 installer from  
    `https://pkgs.netbird.io/windows/x64`.
  - Runs the installer silently (`/S`).
  - Tracks the last GUI version in `gui-state.json` to avoid reinstalling the same version on every run.

- 🔁 **Script self-update** (since `0.2.0`)  
  - Reads the latest release of this repository: `NetHorror/netbird-delayed-auto-update-windows`.
  - Compares the release tag (e.g. `0.2.0`) with the local `$ScriptVersion` inside the script.
  - If the remote version is newer:
    1. Tries `git pull --ff-only` in the repository root (if the script is inside a git repo).
    2. If git is not available or it is not a repo, downloads
       `netbird-delayed-update.ps1` from the matching tag on `raw.githubusercontent.com` and overwrites the local file.
  - The updated script is used on the **next** run.

- 🧰 **Single script, three modes**
  - Install scheduled task
  - Uninstall scheduled task
  - Run delayed-update logic (what the task uses)

- ⚙️ **Optional catch-up after missed runs**  
  `-StartWhenAvailable` / `-r` enables Task Scheduler option *“Run task as soon as possible after a scheduled start is missed”*.

- 📜 **Detailed logs**  
  Every decision (new version seen, still aging, upgraded, up-to-date, GUI updated/skipped, self-update result, errors) is logged to a timestamped file.

---

## Requirements

- Windows Server 2019+ or Windows 10+
- PowerShell 5+
- Installed [Chocolatey](https://chocolatey.org)
- NetBird installed via Chocolatey:

~~~powershell
choco install netbird -y
~~~

- Optional: [Git](https://git-scm.com) – for `git clone` and for script self-update via `git pull`.
- Administrator privileges to create/remove scheduled tasks.
- Outbound HTTPS to:
  - `chocolatey.org` – to read package versions,
  - `api.github.com` – to read NetBird and script releases,
  - `pkgs.netbird.io` – to download the NetBird GUI installer,
  - `raw.githubusercontent.com` – HTTP fallback for script self-update.

---

## Repository structure

~~~text
netbird-delayed-auto-update-windows/
├─ README.md
├─ CHANGELOG.md
├─ LICENSE
└─ netbird-delayed-update.ps1
~~~

All logic lives in the single `netbird-delayed-update.ps1` script.

---

## Quick start

Open **PowerShell as Administrator**:

~~~powershell
# Clone and install scheduled task with defaults:
#   DelayDays=10, MaxRandomDelaySeconds=3600, DailyTime=04:00,
#   run as SYSTEM with highest privileges and bypass script execution policy

git clone https://github.com/NetHorror/netbird-delayed-auto-update-windows.git
cd netbird-delayed-auto-update-windows
powershell -ExecutionPolicy Bypass -File netbird-delayed-update.ps1 -Install
~~~

If you do not have Git installed, you can download the repository as a ZIP in GitHub
(**Code → Download ZIP**), extract it and run:

~~~powershell
cd C:\Path\To\netbird-delayed-auto-update-windows

# Install scheduled task:
.\netbird-delayed-update.ps1 -Install
~~~

After successful installation, you should see a scheduled task named:

> `NetBird Delayed Choco Update`

in the Windows Task Scheduler.

---

## Modes and parameters

The script has three modes:

- **Run mode** (default – no `-Install` / `-Uninstall`)  
  Performs a single delayed-update check. This is what the scheduled task runs every day.

- **Install mode** – `-Install` / `-i`  
  Creates or updates the scheduled task that runs this script once per day.

- **Uninstall mode** – `-Uninstall` / `-u`  
  Removes the scheduled task (optionally the state/logs directory).

### Install examples

~~~powershell
# Install scheduled task with defaults
.\netbird-delayed-update.ps1 -Install

# Install task that waits 10 days and uses no random delay
.\netbird-delayed-update.ps1 -Install -DelayDays 10 -MaxRandomDelaySeconds 0

# Install task that also runs as soon as possible after a missed schedule
.\netbird-delayed-update.ps1 -Install -StartWhenAvailable
# or shorter:
.\netbird-delayed-update.ps1 -i -r

# Install the task to run as the current user instead of SYSTEM
.\netbird-delayed-update.ps1 -Install -RunAsCurrentUser
~~~

### Supported options

- `-DelayDays N` – how many days a new Chocolatey NetBird version must stay unchanged before upgrade  
  (default: `10`).

- `-MaxRandomDelaySeconds N` – max random delay (seconds) added after the scheduled time  
  (default: `3600`).

- `-DailyTime "HH:mm"` – time of day (24h) when the task should start  
  (default: `04:00`).

- `-TaskName NAME` – name of the scheduled task  
  (default: `NetBird Delayed Choco Update`).

- `-RunAsCurrentUser` – run the scheduled task as the current user instead of `SYSTEM`.

- `-PackageName NAME` – Chocolatey package name (default: `netbird`).

- `-StartWhenAvailable` / `-r` – when used with `-Install`, enables Task Scheduler option  
  *“Run task as soon as possible after a scheduled start is missed”*.

- `-RemoveState` – when used with `-Uninstall`, also remove the state/log directory.

---

## How it works

### 1. Scheduled task

Once per day, Task Scheduler runs something like:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Path\To\netbird-delayed-update.ps1" `
  -DelayDays <DelayDays> `
  -MaxRandomDelaySeconds <MaxRandomDelaySeconds>
~~~

### 2. Daemon update (Chocolatey)

On each run, the script:

1. (Optionally) sleeps for a random number of seconds between `0` and `MaxRandomDelaySeconds`.
2. Checks that `choco` (Chocolatey) is available in `PATH`.
3. Reads the locally installed NetBird version from Chocolatey (`PackageName`, default `netbird`).
4. Reads the candidate NetBird version from the Chocolatey repository.
5. If NetBird is not installed locally, exits without doing anything (no auto-install).
6. Loads `state.json`, which stores:
   - `CandidateVersion` – last candidate version seen in the repo;
   - `FirstSeenUtc` – when that version was first observed;
   - `LastCheckUtc` – when it was last checked.
7. If the candidate version changed (or state is missing), it:
   - logs that a new candidate version was detected,
   - resets the aging timer by setting `FirstSeenUtc` to now.
8. Computes the candidate age in days.
   - If `age < DelayDays`, logs that it is too early and exits without upgrade.
9. If `age >= DelayDays` **and** the local version is older:
   - logs the planned upgrade;
   - tries to stop the `Netbird` Windows service;
   - runs `choco upgrade <PackageName> -y --no-progress`;
   - tries to start the service again;
   - saves updated `state.json`.
10. If the local version is already up to date (or newer), it logs that there is nothing to do and only touches timestamps in `state.json`.

Short-lived or “bad” versions that get replaced quickly in Chocolatey never pass the `DelayDays` filter and therefore are never deployed.

### 3. GUI auto-update

After the Chocolatey/daemon part, the script:

1. Fetches the latest NetBird release from GitHub and extracts the version (e.g. `0.60.7`).
2. Reads `gui-state.json` to see which GUI version it last installed (if any).
3. If the stored GUI version equals the latest release, it logs that GUI is already up to date and exits this phase.
4. If a newer GUI version is available:
   - downloads the current Windows x64 installer from  
     `https://pkgs.netbird.io/windows/x64` to `%TEMP%`;
   - runs the installer silently with `/S`;
   - removes the temporary installer file;
   - updates `gui-state.json` with:
     - `LastGuiVersion` – the version from the latest release;
     - `LastGuiUpdateUtc` – timestamp of the update.

### 4. Script self-update

At the beginning of each run (before the daemon/GUI logic), the script can optionally self-update:

1. Requests the latest release for this repository (`NetHorror/netbird-delayed-auto-update-windows`).
2. Compares the release tag (e.g. `0.2.0`) with the local `$ScriptVersion` constant defined at the top of the script.
3. If the remote version is newer:

   - Tries to find a `.git` directory by walking up from the script path.
   - If found and `git` is available:
     - runs `git pull --ff-only` in the repository root;
     - logs success or failure.
   - If git is not available or no repository is found:
     - downloads `netbird-delayed-update.ps1` from  
       `https://raw.githubusercontent.com/NetHorror/netbird-delayed-auto-update-windows/<tag>/netbird-delayed-update.ps1`;
     - overwrites the local script file.

4. The current run continues with the existing code; the new version of the script will be used on the **next** run.

To disable self-update, you can either:

- set `$ScriptRepo` to an empty string in the script, or
- comment out the call to `Invoke-SelfUpdateByRelease` at the end of the file.

---

## Logs and state

All state and log files live under:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\
~~~

- `state.json` – aging and last-seen information for the Chocolatey package.
- `gui-state.json` – last GUI version installed and timestamp.
- `netbird-delayed-update-YYYYMMDD-HHMMSS.log` – log per run.

Typical things you can see in logs:

- when a candidate daemon version was first seen and how long it aged;
- when an upgrade actually happened;
- GUI update decisions (skipped/already up to date/downloaded/installed);
- script self-update attempts and outcomes;
- warnings or errors (Chocolatey not found, version parsing, HTTP failures, etc.).

---

## Task Scheduler notes

When random delay is enabled, the scheduled task may show:

- `Status = Running`
- `Last Run Result = 0x41301` (*The task is currently running*).

This usually just means the script is sleeping during the random delay window.

If you install the task **without** `-StartWhenAvailable` (default):

- if the machine is powered off at the scheduled time (e.g. `04:00`),
- that day’s run is skipped,
- the next run happens at the next scheduled time.

If you install the task **with** `-StartWhenAvailable` / `-r`:

- Task Scheduler will also run the task as soon as possible after a missed start,
- e.g. right after a laptop is powered on in the morning,
- similar to a "Run at load" behaviour on other platforms.

---

## Manual one-off run (for testing)

You can run the delayed-update logic manually, without Task Scheduler:

~~~powershell
# Run immediately, no random delay, no "aging" period (for testing)
.\netbird-delayed-update.ps1 -DelayDays 0 -MaxRandomDelaySeconds 0
~~~

This will:

- perform all checks,
- log decisions,
- update `state.json`,
- and, if needed, run `choco upgrade netbird -y --no-progress` and the GUI installer.

---

## Uninstall

To remove the scheduled task (keep state/logs):

~~~powershell
cd netbird-delayed-auto-update-windows
.\netbird-delayed-update.ps1 -Uninstall
# or shorter:
# .\netbird-delayed-update.ps1 -u
~~~

To remove both the task and the state/logs directory:

~~~powershell
cd netbird-delayed-auto-update-windows
.\netbird-delayed-update.ps1 -Uninstall -RemoveState
# or shorter:
# .\netbird-delayed-update.ps1 -u -RemoveState
~~~

NetBird itself is not removed – only the delayed-update mechanism.

---

## Changelog

The full list of notable changes and release history is maintained in:

~~~text
CHANGELOG.md
~~~

Each GitHub Release corresponds to an entry in `CHANGELOG.md` and a matching script `$ScriptVersion`.

---

## Versioning

- Script version is stored in `$ScriptVersion` at the top of `netbird-delayed-update.ps1`.
- GitHub releases of this repository use plain tags like `0.2.0` (no leading `v`).
- Self-update compares `$ScriptVersion` with the latest release tag and updates the script when the tag is newer.

For detailed history of changes, see `CHANGELOG.md` and the GitHub Releases page.
