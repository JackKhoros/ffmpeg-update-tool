# Changelog

## v8.5.1 — 2025-12-02
### Added / Changed
- SHA256 verification step now displays a clear result on the same line:
  - `PASSED` in bright green when checksum matches.
  - `NOT PASSED` in bright red when checksum does not match.
- Additional detailed error messages on checksum failure.
- Retry logic now mirrors the low-speed download behavior: one automatic retry, then abort on repeated failure.
- All temporary files (ZIP, checksum file, temp directories) are still guaranteed to be cleaned up on both success and failure.

## v8.5 — 2025-12-02 (internal)
### Added
- SHA256 integrity verification for downloaded archives:
  - downloads `checksums.sha256` from the selected BtbN release;
  - extracts the correct checksum for the actual asset name (supports both standard and snapshot naming);
  - computes local SHA256 and compares them.
- Support for two master filename patterns:
  - `ffmpeg-master-latest-win64-gpl.zip`
  - `ffmpeg-N-*-win64-gpl.zip`

### Changed
- If the checksum file is missing or no matching entry is found, the script prints a yellow warning and continues without SHA validation (ETag + file size remain active).
- On SHA256 mismatch:
  - the ZIP file is deleted immediately;
  - a red error message is displayed;
  - the script retries the download once.
- If checksum mismatch happens again, the update is aborted, temporary files are cleaned up, and `metadata.json` is not updated.

## v8.4.1 — 2025-12-02
### Changed
- Improved message formatting when using a master asset with a non-standard name:
  - `[INFO]` tag now uses white brackets (consistent with other tags).
  - The text `Using master asset with non-standard name:` uses more intense yellow for emphasis.
  - The filename itself remains in standard yellow for readability.
- Updated banner and internal version to `v8.4.1`.

## v8.4 — 2025-12-01
### Added
- Support for snapshot-style master filenames:
  - `ffmpeg-N-*-win64-gpl.zip`
- Automatic detection of such filenames and display of a yellow informational warning.

### Changed
- Master asset detection now checks both patterns:
  - `ffmpeg-master-latest-win64-gpl.zip`
  - `ffmpeg-N-*-win64-gpl.zip`
- Release selection logic preserved:
  - `/releases/latest` is used only if it truly corresponds to the newest build.
  - Otherwise, the script selects the newest suitable autobuild from `/releases?per_page=10`.
- Refactored the master asset detection helper; updated script banner to `v8.4`.

## v8.3 — 2025-12-01
### Added
- “Smart latest release detection”:
  - queries both `/releases/latest` and recent releases (`?per_page=10`);
  - compares `published_at` timestamps to avoid GitHub’s delayed Latest tag updates.

### Changed
- The script filters releases only containing:
  - `ffmpeg-master-latest-win64-gpl.zip`
- Among them, the newest one by publication date is selected.
- Added clear output:
[CHECK] Selected build: <tag> (published <datetime>)
- Log output improved and unnecessary lines removed.
- Updated version to `v8.3` and refined GitHub API access code.

## v8.2.1 — 2025-11-29
### Added / Changed
- Added version banner printed immediately at script startup (before any `[CHECK]` messages).
- Updated header and internal metadata to `v8.2.1`.
- Minor internal cleanup.

## v8.2 — 2025-11-29
### Added
- Fully redesigned GitHub API logic:
- no longer relies on `/releases/latest`;
- selects the most recent autobuild from tag list.
- Added strict asset checks to ensure:
- `ffmpeg-master-latest-win64-gpl.zip` is present.
- Script now prints the selected tag:
[CHECK] Using release: autobuild-YYYY-MM-DD-HH-MM

### Fixed
- Fixed “Asset not found” issues caused by GitHub UI/endpoint changes.
- Added robust fallback logic for incomplete or noisy API responses.
- Made script resilient to hidden or modified Releases UI sections.

## v8.1 — 2025-11-28
### Fixed
- Fixed issue where Windows Explorer failed to refresh timestamps after updating FFmpeg binaries.
- Guaranteed cleanup of temporary folders on:
- failed downloads,
- user interruptions,
- unexpected script termination.

### Changed
- Before copying new binaries, old ones are explicitly deleted:
- ensures correct Windows timestamp refresh;
- avoids metadata inconsistencies.
- Added post-update `ffmpeg -version` validation.
- Improved message formatting and status output.

## v8.0 (Public Release) — 2025-11-26
### Initial public release
- First public release of the FFmpeg auto-updater for Windows.
- Core features:
- update detection via GitHub API and ETag;
- fast and reliable downloading using Windows `curl.exe`;
- two-phase download logic with slow-speed detection and optional retry;
- custom progress bar with no flicker and single-line updates;
- safe update of FFmpeg binaries (`ffmpeg.exe`, `ffprobe.exe`, `ffplay.exe`);
- automatic cleanup of temporary files;
- portable: works in the folder where it is placed, no installation needed.
