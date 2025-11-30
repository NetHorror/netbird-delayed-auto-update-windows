# NetBird Delayed Auto-Update for Windows (Chocolatey)

Delayed (staged) auto-update for the NetBird client on Windows (Server 2019+ / Windows 10+).

> Don’t upgrade NetBird clients immediately when a new version appears in Chocolatey.  
> Instead, wait **N days**. If that version is quickly replaced (hotfix / bad release),  
> clients will **never** upgrade to it.

---

## Idea

* A **candidate** NetBird version in the Chocolatey repository must “age” for **N days** before being deployed.
* If the same version stays in the repo for `DelayDays` without changes, the installed client is upgraded.
* If a **newer** version appears in the repo, the aging timer is reset and we start counting again.
* NetBird is **not auto-installed** – only upgraded if it is already installed locally. 

State is stored in:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\state.json
~~~

Logs are stored in the same directory.

---

## Features

- ⏳ **Version aging** – only upgrades after a version has been stable in Chocolatey for `DelayDays`.
- 🕓 **Daily scheduled task** – runs once per day at a configurable time (default: `04:00`).
- 🎲 **Optional random delay** – spreads the actual execution time over a random window (`MaxRandomDelaySeconds`).
- 🧱 **Local state tracking** – remembers last seen repo version and when it was first observed.
- 🛑 **No silent install** – if NetBird is not installed locally, the script exits without doing anything.
- 📜 **Detailed logs** – logs each decision (first seen, still aging, upgraded, already up-to-date, etc.).
- 🧩 **Single script** – one PowerShell file handles install, uninstall and the actual update logic.

---

## Requirements

- Windows Server 2019+ or Windows 10+  
- PowerShell 5+  
- Installed [Chocolatey](https://chocolatey.org)  
- [Git for Windows](https://git-scm.com/download/win) (for installation via `git clone`)  
- NetBird installed via Chocolatey:

~~~powershell
choco install netbird -y
~~~

---

## Repository structure

~~~text
netbird-delayed-auto-update-windows/
├─ README.md
├─ LICENSE
└─ netbird-delayed-update.ps1
~~~

---

## Quick start

Open **PowerShell as Administrator**:

~~~powershell
git clone https://github.com/NetHorror/netbird-delayed-auto-update-windows.git
cd netbird-delayed-auto-update-windows

# Default: DelayDays=3, MaxRandomDelaySeconds=3600, time 04:00, run as SYSTEM
.\netbird-delayed-update.ps1 -Install
# or shorter:
# .\netbird-delayed-update.ps1 -i
~~~

If you don't have Git installed, you can download the repository as a ZIP from GitHub ("Code" → "Download ZIP"),
extract it and run:

~~~powershell
cd C:\path\to\netbird-delayed-auto-update-windows
.\netbird-delayed-update.ps1 -Install
~~~

After successful installation, you should see a scheduled task named:

> **NetBird Delayed Choco Update**

in the Windows Task Scheduler.

---

## Installation options

The script has three modes:

- **Install mode** – `-Install` / `-i`  
  Creates or updates the scheduled task.
- **Uninstall mode** – `-Uninstall` / `-u`  
  Removes the scheduled task (optionally state/logs).
- **Run mode** – no `-Install`/`-Uninstall`  
  Performs a single delayed-update check. This is what Task Scheduler uses.

### Install parameters

~~~powershell
# Wait 5 days, no random delay, run at 03:30
.\netbird-delayed-update.ps1 -Install -DelayDays 5 -MaxRandomDelaySeconds 0 -DailyTime "03:30"

# Run the task as the current user (instead of SYSTEM)
.\netbird-delayed-update.ps1 -Install -RunAsCurrentUser
~~~

**Parameters (summary):**

- `-DelayDays` – how many days a new Chocolatey NetBird version must stay unchanged before upgrade (default: `3`).
- `-MaxRandomDelaySeconds` – max random delay added after the scheduled start time (default: `3600` seconds).
- `-DailyTime` – time of day in `HH:mm` (24h format) when the task should start (default: `04:00`).
- `-TaskName` – scheduled task name (default: `NetBird Delayed Choco Update`).
- `-RunAsCurrentUser` – run scheduled task under the current user instead of `SYSTEM`.

---

## How it works

The single script `netbird-delayed-update.ps1` can either install the scheduled task or run the delayed-update logic.

When the scheduled task triggers (daily at `DailyTime`), it runs:

~~~text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "netbird-delayed-update.ps1" -DelayDays X -MaxRandomDelaySeconds Y
~~~

The script then:

1. Optionally sleeps for a **random delay** between `0` and `MaxRandomDelaySeconds` seconds.
2. Checks that Chocolatey (`choco`) is available.
3. Reads the **locally installed** NetBird version (Chocolatey package).
4. Reads the **repository (latest)** NetBird version from Chocolatey.
5. If NetBird is not installed, the script exits (no auto-install).
6. Maintains a `state.json` file with:
   - the current candidate version from Chocolatey,
   - when it was first seen (`FirstSeenUtc`),
   - when it was last checked.
7. If a **new candidate version** appears in the repo:
   - the aging timer is reset (new `FirstSeenUtc`).
8. If the candidate version has “aged” for at least `DelayDays` and the local version is older:
   - tries to stop the NetBird Windows service (if present),
   - runs:

     ~~~powershell
     choco upgrade netbird -y --no-progress
     ~~~

   - starts the NetBird service again,
   - writes detailed log entries.

Short-lived or “bad” versions that are quickly replaced in Chocolatey are **never** deployed to your clients,  
because they fail to reach the required `DelayDays` age.

---

## Task Scheduler status

When checking the task in **Task Scheduler** or via PowerShell, you may see:

- `LastRunResult = 0` – last run finished successfully.
- `LastRunResult = 0x41301` (or `267009` in PowerShell) –  
  **"The task is currently running"**.  
  For this script that usually means it is sleeping inside the random delay
  (`MaxRandomDelaySeconds`) before performing the actual checks.
- `LastRunResult = 0x41303` (or `267011`) – the task has been triggered but has not yet completed its first run.

This is expected behavior when a random delay is configured.  
As soon as the script finishes, `LastRunResult` becomes `0` and a new log file appears in:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\
~~~

---

## Manual one-off run (for testing)

You can run the delayed-update logic manually without touching the scheduled task:

~~~powershell
# Run immediately, no random delay, no "aging" period (for testing)
.\netbird-delayed-update.ps1 -DelayDays 0 -MaxRandomDelaySeconds 0
~~~

This will:

- perform all checks,
- log the decisions,
- update `state.json`,
- and optionally run `choco upgrade` if needed.

---

## Logs

Log files are stored in:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\
~~~

File names look like:

~~~text
netbird-delayed-update-YYYYMMDD-HHMMSS.log
~~~

You can review these logs to see:

- when a candidate version was first observed,
- how long it aged,
- when an upgrade actually happened,
- any warnings or errors (e.g. missing `choco` or NetBird package).

---

## Uninstall

To remove the scheduled task (but keep state/logs):

~~~powershell
.\netbird-delayed-update.ps1 -Uninstall
# or shorter:
# .\netbird-delayed-update.ps1 -u
~~~

To remove both the task **and** the state/logs directory:

~~~powershell
.\netbird-delayed-update.ps1 -Uninstall -RemoveState
~~~

NetBird itself is **not** removed – only the delayed update mechanism.

---

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)  
![Platform: Windows](https://img.shields.io/badge/platform-Windows-informational)  
![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-lightgrey)
