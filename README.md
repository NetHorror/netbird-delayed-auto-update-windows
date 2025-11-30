# NetBird Delayed Auto-Update for Windows (Chocolatey)

Delayed (staged) auto-update for the NetBird client on Windows (Server 2019+ / Windows 10+)

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

```text
C:\ProgramData\NetBirdDelayedUpdate\state.json
```
Logs are stored in the same directory.

## Features

- ⏳ **Version aging** – only upgrades after a version has been stable in Chocolatey for `DelayDays`.
- 🕓 **Daily scheduled task** – runs once per day at a configurable time (default: `04:00`).
- 🎲 **Optional random delay** – spreads the actual execution time over a random window (`MaxRandomDelaySeconds`).
- 🧱 **Local state tracking** – remembers last seen repo version and when it was first observed.
- 🛑 **No silent install** – if NetBird is not installed locally, the script exits without doing anything.
- 📜 **Detailed logs** – logs each decision (first seen, still aging, upgraded, already up-to-date, etc.).

## Requirements

- Windows Server 2019+ or Windows 10+  
- PowerShell 5+  
- Installed [Chocolatey](https://chocolatey.org)  
- NetBird installed via Chocolatey:


```powershell
choco install netbird -y
```
## Repository structure
```text
netbird-delayed-auto-update-windows/
├─ README.md
├─ NetBird-Delayed-Choco-Update.ps1
├─ install-netbird-delayed-update.ps1
└─ uninstall-netbird-delayed-update.ps1
```
## Quick start

Open **PowerShell as Administrator**:

```powershell
git clone https://github.com/NetHorror/netbird-delayed-auto-update-windows.git
cd netbird-delayed-auto-update-windows

# Default: DelayDays=3, MaxRandomDelaySeconds=3600, time 04:00, run as SYSTEM
.\install-netbird-delayed-update.ps1
```

After successful installation, you should see a scheduled task named:

> **NetBird Delayed Choco Update**

in the Windows Task Scheduler.

---

## Installation options

The installer script accepts several parameters:

```powershell
# Wait 5 days, random delay up to 10 minutes, run at 03:30
.\install-netbird-delayed-update.ps1 -DelayDays 5 -MaxRandomDelaySeconds 600 -DailyTime "03:30"

# Run the task as the current user (instead of SYSTEM)
.\install-netbird-delayed-update.ps1 -RunAsCurrentUser
```

**Parameters (summary):**

- `-DelayDays` – how many days a new Chocolatey NetBird version must stay unchanged before upgrade.
- `-MaxRandomDelaySeconds` – max random delay added after the scheduled time.
- `-DailyTime` – time of day in `HH:mm` (24h format) when the task should start.
- `-RunAsCurrentUser` – run scheduled task under the current user instead of `SYSTEM`.

---

## How it works

Once per day (with the optional random delay), the scheduled task runs  
`NetBird-Delayed-Choco-Update.ps1`, which does the following:

1. Reads the **locally installed** NetBird version (Chocolatey package).
2. Reads the **repository (latest)** NetBird version from Chocolatey.
3. If NetBird is not installed, the script exits (no auto-install).
4. If a **new repo version** appears:
   - On the first sighting, it records the version and current timestamp into `state.json` and exits.
   - If the version changes again later, the aging timer is reset.
5. If the **same repo version** has been present for at least `DelayDays` and the **local version is older**:
   - Tries to **stop the NetBird Windows service** (if present).
   - Runs:

     ```powershell
     choco upgrade netbird -y --no-progress
     ```

   - Starts the NetBird service again.
   - Writes detailed log entries to the log file in `C:\ProgramData\NetBirdDelayedUpdate\`.

This way, short-lived or “bad” versions that are quickly replaced in Chocolatey are **never** deployed to your clients.

---

## Logs

Log files are stored in:

```
C:\ProgramData\NetBirdDelayedUpdate\
```

File names look like:

```
netbird-delayed-update-YYYYMMDD-HHMMSS.log
```

You can review these logs to see:

- when a candidate version was first observed,
- how long it aged,
- when an upgrade actually happened.

---

## Uninstall

To remove the scheduled task (but keep state/logs):

```powershell
cd netbird-delayed-auto-update-windows
.\uninstall-netbird-delayed-update.ps1
```

To remove both the task **and** the state/logs directory:

```powershell
cd netbird-delayed-auto-update-windows
.\uninstall-netbird-delayed-update.ps1 -RemoveState
```

NetBird itself is **not** removed – only the delayed update mechanism.

---

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/platform-Windows-informational)
![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-lightgrey)

