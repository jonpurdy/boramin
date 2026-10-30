# Session handoff — October 30, 2026

Read `AGENTS.md`, then `README.md` and `testflight.md`.

## Completed

- Added playback Show Debug Info menus on tvOS, iOS and Mac; committed as `91d12e4`. Built/deployed all platforms during the session.
- Prepared 0.4 (4) archives for all three platforms. Main regression suite and offline browsing/cancellation probes passed. Archive audits passed identity/version, credential exclusion, signatures, app/private-framework symbol UUIDs and media linkage. See `testflight.md` for paths and exact distribution status.
- Latest developer 0.4 (4) installed on Apple TV. Mac local build also includes the later icon fix; test device last received the menus build before the version bump.
- Rebuilt Mac icon from shared Icon Composer artwork using `tools/create_macos_icon.swift`, with transparent padding. Installed locally; user confirmed it after reopening. Existing 0.4 archives were deliberately left unchanged.
- Added simple `AGENTS.md`; moved agent-oriented architecture notes from README. Updated diagnostics and release documentation.

## Remaining / cautions

- Apple TV navigation/background-reopen crash is unresolved. No debugger stack or useful crash report captured; do not claim a fix. User prefers a fast TestFlight crash-report workflow over prolonged device-report hunting. Simulator support is not configured; Xcode 26.3 / tvOS 27 debugger compatibility was suspected, not proven.
- the maintainer reports uploading Mac 0.4 (4). Other platform uploads and final Production distribution entitlements were not verified. A future icon release needs a fresh archive and unused build number.
- Mac SMB failure was local-network permission denial, now resolved. No connection-code change was made.
- Mac icon caching can show the old checkerboard despite correct packaged assets. Reopening resolved it. Keep transparency and regenerate from clean shared artwork.
- Pending Git changes: 0.4 version/build bump, Mac icons/generator, README/AGENTS and release/diagnostic/handoff docs. Not committed. Personal `_to do.txt` must remain untouched and uncommitted.
- Preserve release archives/dSYMs. Audit/test logs are in ignored `build/TestFlight/0.4/` and `build/testflight-0.4-*`.
