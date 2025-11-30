# NetBird Delayed Auto-Update for Windows (Chocolatey)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: Windows](https://img.shields.io/badge/platform-Windows-informational) ![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-brightgreen) ![Package manager: Chocolatey](https://img.shields.io/badge/package%20manager-Chocolatey-8A4513)

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
* Uses **Windows Task Scheduler** to run a PowerShell script once per day.

State and logs are stored in:

~~~text
C:\ProgramData\NetBirdDelayedUpdate\
~~~

`state.json` keeps the “aging” state, logs go into timestamped `netbird-delayed-update-*.log` files.

---

## Features

- ⏳ **Version aging** – only upgrades after a version has been stable in Chocolatey for `DelayDays`.
- 🕓 **Daily scheduled task** – runs once per day at a configurable time (default: `04:00`).
- 🎲 **Optional random delay** – spreads the actual execution time over a random window (`MaxRandomDelaySeconds`).
- 🧱 **Local state tracking** – remembers last seen repo version and when it was first observed.
- 🛑 **No silent install** – if NetBird is not installed locally, the script exits without doing anything.
- 📜 **Detailed logs** – logs each decision (first seen, still aging, upgraded, already up-to-date, etc.).
- 🧩 **Single script** – one PowerShell script handles install, uninstall and the actual update logic.
- ⚙️ **Optional catch-up after missed runs** – `-StartWhenAvailable` / `-r` flag enables Task Scheduler
  option “Run task as soon as possible after a scheduled start is missed”.

---

## Requirements

- Windows Server 2019+ or Windows 10+
- PowerShell 5+
- Installed [Chocolatey](https://chocolatey.org)
- NetBird installed via Chocolatey:

~~~powershell
choco install netbird -y
~~~

- Optional: [Git](https://git-scm.com) (for installation via `git clone`) –  
  otherwise you can use "Download ZIP" on GitHub.
- Administrator privileges (to create/remove scheduled tasks).

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

# Install scheduled task with defaults:
#   DelayDays=3, MaxRandomDelaySeconds=3600, DailyTime=04:00,
#   run as SYSTEM with highest privileges.
.\netbird-delayed-update.ps1 -i
~~~

If you don't have Git installed, you can download the repository as a ZIP from GitHub  
("Code" → "Download ZIP"), extract it and run:

~~~powershell
cd C:\Path\To\netbird-delayed-auto-update-windows

# Install scheduled task:
.\netbird-delayed-update.ps1 -Install
~~~

After successful installation, you should see a scheduled task named:

> **NetBird Delayed Choco Update**

in the Windows Task Scheduler.

---

## Installation options

The script has three modes:

- **Run mode (default)** – no `-Install` / `-Uninstall`  
  Performs a single delayed-update check. This is what the scheduled task uses.
- **Install mode** – `-Install` / `-i`  
  Creates or updates the scheduled task that runs this script once per day.
- **Uninstall mode** – `-Uninstall` / `-u`  
  Removes the scheduled task (optionally state/logs).

### Install parameters

Examples:

~~~powershell
# Install scheduled task with defaults
.\netbird-delayed-update.ps1 -Install

# Install task that waits 5 days and uses no random delay
.\netbird-delayed-update.ps1 -Install -DelayDays 5 -MaxRandomDelaySeconds 0

# Install task that also runs as soon as possible after a missed schedule
.\netbird-delayed-update.ps1 -Install -StartWhenAvailable
# or shorter:
.\netbird-delayed-update.ps1 -i -r

# Install the task to run as the current user instead of SYSTEM
.\netbird-delayed-update.ps1 -Install -RunAsCurrentUser
~~~

Supported options:

- `-DelayDays N` – how many days a new Chocolatey NetBird version must stay unchanged before upgrade  
  (default: `3`).
- `-MaxRandomDelaySeconds N` – max random delay added after the scheduled time  
  (default: `3600` seconds).
- `-DailyTime "HH:mm"` – time of day (24h) when the task should start  
  (default: `04:00`).
- `-TaskName NAME` – name of the scheduled task (default: `NetBird Delayed Choco Update`).
- `-RunAsCurrentUser` – run the scheduled task as the current user instead of `SYSTEM`.
- `-PackageName NAME` – Chocolatey package name (default: `netbird`).
- `-StartWhenAvailable` / `-r` – when used with `-Install`, enables Task Scheduler option  
  **“Run task as soon as possible after a scheduled start is missed”**. Useful for laptops
  that are often powered off at the scheduled time.
- `-RemoveState` – when used with `-Uninstall`, also remove the state/log directory.

---

## How it works (details)

Once per day, the scheduled task runs:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Path\To\netbird-delayed-update.ps1" `
  -DelayDays <DelayDays> `
  -MaxRandomDelaySeconds <MaxRandomDelaySeconds>
~~~

On each run, the script:

1. Optionally sleeps for a **random delay** between `0` and `MaxRandomDelaySeconds` seconds.
2. Verifies that `choco` (Chocolatey) is available in `PATH`.
3. Reads the **locally installed** NetBird version (Chocolatey package `PackageName`).
4. Reads the **repository (latest)** NetBird version from Chocolatey.
5. If NetBird is not installed locally, the script exits (no auto-install).
6. Loads the current `state.json` from `C:\ProgramData\NetBirdDelayedUpdate\`, which contains:
   - last candidate version (`CandidateVersion`),
   - when it was first seen (`FirstSeenUtc`),
   - when it was last checked (`LastCheckUtc`).
7. If a **new repo version** appears (or there was no state before):
   - logs that a new candidate version was detected,
   - sets `FirstSeenUtc` to now and starts the aging period.
8. Computes the **age in days** of the candidate version.
   - If `age < DelayDays`:
     - logs that it is “too early to update” and exits without upgrade.
9. If `age ≥ DelayDays` **and** the **local version is older** than the candidate:
   - logs the planned upgrade,
   - tries to **stop the NetBird Windows service** (if present),
   - runs:

     ~~~powershell
     choco upgrade netbird -y --no-progress
     ~~~

   - tries to start the NetBird service again,
   - saves updated state with the latest timestamps.
10. If the local version is already `>=` candidate version:
    - logs that no upgrade is required,
    - updates the state timestamps and exits.

Short-lived or “bad” versions that are quickly replaced in Chocolatey are **never** deployed to your clients,  
because they do not survive the `DelayDays` aging period.

---

## Task Scheduler notes

When the script uses a **random delay**, the scheduled task may appear as:

- `Status = Running`
- `Last Run Result = 0x41301` (The task is currently running)

In this case it usually just means the script is **sleeping inside the random delay window** before doing its checks.

If you install the task **without** `-StartWhenAvailable` (default):

- if the machine is **powered off** at the scheduled time (e.g. 04:00),
- the run for that day is simply **skipped**,
- and the next run will happen at the next scheduled time.

If you install the task **with** `-StartWhenAvailable` / `-r`:

- Task Scheduler will also run the task **as soon as possible after a missed start**,
- for example, after the laptop is turned on in the morning,
- which is similar to `RunAtLoad=true` behaviour on macOS.

---

## Manual one-off run (for testing)

You can run the delayed-update logic manually without using Task Scheduler:

~~~powershell
# Run immediately, no random delay, no "aging" period (for testing)
.\netbird-delayed-update.ps1 -DelayDays 0 -MaxRandomDelaySeconds 0
~~~

This will:

- perform all checks,
- log the decisions,
- update `state.json`,
- and, if needed, run `choco upgrade netbird -y --no-progress`.

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
- any warnings or errors (Chocolatey not found, version parsing issues, etc.).

---

## Uninstall

To remove the scheduled task (but keep state/logs):

~~~powershell
cd netbird-delayed-auto-update-windows
.\netbird-delayed-update.ps1 -Uninstall
# or shorter:
# .\netbird-delayed-update.ps1 -u
~~~

To remove both the task **and** the state/logs directory:

~~~powershell
cd netbird-delayed-auto-update-windows
.\netbird-delayed-update.ps1 -Uninstall -RemoveState
# or shorter:
# .\netbird-delayed-update.ps1 -u -RemoveState
~~~

NetBird itself is **not** removed – only the delayed update mechanism.

---
