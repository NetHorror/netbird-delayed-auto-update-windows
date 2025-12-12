# Changelog

All notable changes to this project will be documented in this file.  

## [0.2.2] - 2025-12-13

### Added
- More robust GitHub API requests: enforced TLS 1.2 and added explicit `User-Agent`/`Accept` headers.
- Better Windows service restart logic: automatic service name detection if `Netbird` is not found.

### Changed
- Scheduled Task now runs PowerShell with `-NoProfile` for predictable execution.
- Stored timestamp parsing is stricter and safer (`RoundtripKind` / ISO 8601 `"o"` parsing).

### Fixed
- PowerShell 7+ compatibility issues caused by legacy `-UseBasicParsing`.
- GUI installer handling now validates process exit code and does not update GUI state on failure.

## [0.2.1] – 2025-12-09

### Added

- New parameter: `-LogRetentionDays` (default: 60 days).
  - Log files `netbird-delayed-update-*.log` in `C:\ProgramData\NetBirdDelayedUpdate\` older than `LogRetentionDays` are automatically deleted on each run.
  - `LogRetentionDays = 0` disables log cleanup.

### Changed

- Normalised candidate version “age”:
  - Age in days is now clamped to a minimum of `0` to avoid negative values when system time moves backwards.
  - `DelayDays` comparisons use the clamped value.
- GUI update now runs only when:
  - the NetBird package is installed via Chocolatey, **and**
  - the daemon version was actually upgraded during the current run.
- Documentation updated to describe `LogRetentionDays` and the new behaviour.

## [0.2.0] – 2025-12-08

### Added

- NetBird GUI auto-update:
  - Fetches the latest NetBird release tag from GitHub (for the version number only).
  - Downloads the latest Windows x64 GUI installer from `https://pkgs.netbird.io/windows/x64`.
  - Runs the installer silently (`/S`).
  - Tracks last installed GUI version in `gui-state.json` under `C:\ProgramData\NetBirdDelayedUpdate\` to avoid reinstalling the same version.

- Script self-update:
  - Checks the latest release of this repository via GitHub API.
  - Compares the release tag (e.g. `0.2.0`) with the local `$ScriptVersion`.
  - If newer:
    - attempts `git pull --ff-only` when the script is inside a git repository;
    - falls back to downloading the script from the corresponding tag on `raw.githubusercontent.com` and overwriting the local file.
  - The updated script is used on the **next** run; the current run continues with the old version.

### Changed

- Default `DelayDays` increased from `3` to `10` days to reduce the chance of installing short-lived / bad releases.
- More robust Chocolatey version detection:
  - Installed version: `choco list <package> --localonly --exact --limit-output`.
  - Repository version: `choco search <package> --exact --limit-output`.
  - Versions are parsed from the `name|version|...` format and support 3- or 4-part versions (e.g. `0.60.7` or `0.60.7.1`).
- If the package is not installed locally, the script logs this and exits with code 0 (no error), instead of treating it as a failure.
- Fixed various PowerShell parsing issues in logging code for wider compatibility.

## [0.1.1] – 2025-xx-xx

### Changed

- Improved scheduled task installation and uninstallation:
  - More robust handling when the task already exists.
  - Clearer messages and failure handling.
- Minor logging improvements.

## [0.1.0] – 2025-xx-xx

### Added

- Initial release.
- Delayed Chocolatey upgrade logic for `netbird`:
  - Track candidate version and first-seen timestamp in `state.json`.
  - Only allow upgrade once the version has “aged” for at least `DelayDays`.
  - Optional random delay (`MaxRandomDelaySeconds`) before each run.
- Basic install/uninstall of a daily scheduled task under SYSTEM.
