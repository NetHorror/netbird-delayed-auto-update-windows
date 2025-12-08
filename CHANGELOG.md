# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - 2025-12-08
### Added
- Automatic NetBird GUI update:
  - Fetches latest release version from GitHub.
  - Downloads the latest Windows x64 installer from `https://pkgs.netbird.io/windows/x64`.
  - Installs silently and tracks the last GUI version in `gui-state.json`.
- Script self-update mechanism:
  - Compares local `$ScriptVersion` with the latest GitHub release tag.
  - Tries `git pull --ff-only` if the script is inside a git repository.
  - Falls back to downloading the script from raw GitHub for the release tag when git is not available.

### Changed
- Main run flow now:
  1. Optionally updates the script itself based on GitHub releases.
  2. Runs the existing delayed Chocolatey-based update for the NetBird daemon.
  3. Runs the GUI auto-update logic.
- Logging extended to cover GUI updates and self-update decisions.

### Notes
- Existing state file `state.json` format is unchanged.
- New file `gui-state.json` is used exclusively for GUI version tracking.
- Existing scheduled tasks can continue to be used without changes.

## [0.1.1] - 2025-11-30
### Added
- `-StartWhenAvailable` / `-r` flag to enable Task Scheduler
  “Run task as soon as possible after a scheduled start is missed”.
- Additional README documentation about:
  - Missed runs on laptops and mobile devices.
  - Task Scheduler status / result codes (including `0x41301`).

### Notes
- State file format unchanged compared to `0.1.0`.
- To benefit from the new scheduling behaviour, users can reinstall the task with `-StartWhenAvailable`.

## [0.1.0] - 2025-11-30
### Added
- Initial public release:
  - Delayed (staged) auto-update for NetBird installed via Chocolatey.
  - Version “aging”: new NetBird version must stay in Chocolatey for `DelayDays` before rollout.
  - Daily scheduled task with optional random delay (`MaxRandomDelaySeconds`).
  - Local state tracking in `C:\ProgramData\NetBirdDelayedUpdate\state.json`.
  - Logging of all decisions and upgrade attempts in `C:\ProgramData\NetBirdDelayedUpdate\`.
