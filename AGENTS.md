# Working on BoraMin

- Use supported public APIs and native platform controls. Ask before introducing new custom playback/UI integrations; existing approved integrations may be maintained.
- Share code where practical, while keeping each platform's interface native. Do not change playback routing or add local-file imports incidentally.
- Keep changes focused. Preserve unrelated work and leave the personal `_to do.txt` alone.

## Code and builds

- `Player/`: shared browsing/playback and iOS/tvOS screens. `Shared/`: iCloud. `iOS/`, `tvOS/`, and `MacOS/`: platform code/configuration. `tvOS/TopShelf/`: the tvOS Top Shelf extension, with `TopShelfSnapshot.swift` shared by the tvOS app and extension targets.
- Browsing boundaries: `Browser.swift` owns navigation/presentation; `SMBBrowsingService.swift` owns remote operations; `MetadataProbeService.swift` owns metadata reads; `BrowserScreen.swift` owns screens; `BrowserDiagnostics.swift` owns opt-in probes. Keep those responsibilities separate.
- Use `BoraMin.xcodeproj` and its three platform schemes. Keep project-definition changes in `tools/create_project.py`; regenerate only when needed. See `README.md` for prerequisites and supported targets.
- Mac supports Apple Silicon; current dependencies do not include simulator/Intel slices. Do not silently lower deployment targets to work around SDK warnings.
- Regenerate Mac icons with `swift tools/create_macos_icon.swift`, using the shared Icon Composer artwork. Preserve real transparency.
- Preserve the private `BoraMinMedia` framework boundary: its FFmpeg symbols must not override AetherEngine's. Use `tools/verify_media_linkage.py` when changing media linkage.
- Do not replace ordinary SMB cache locking with timed `try()` polling: that caused confirmed hardware VP9 stutter. See `Tests/VP9-streaming-investigation.md` before changing this path.

## Validation and delivery

- Build affected platforms and run relevant checks. The main suite is `python3 tools/run_tests.py`; offline browser checks are `python3 tools/run_playback_probe.py browsing offline` and `python3 tools/run_playback_probe.py cancellation offline`.
- Run playback probes sequentially: they share a generated project/product. See `Tests/README.md`. Remove the generated diagnostic app afterward to avoid duplicate BoraMin copies; retain useful logs.
- Report what was actually verified. Compilation or an advancing audio clock does not prove visible video playback. Do not interrupt device playback unless requested.
- Never bundle or print credentials. Ignored `default_*.txt` files are local-only and must remain unused by app builds. Do not modify source media while debugging playback.
- Follow `testflight.md` for releases. Upload only when requested; preserve archives/dSYMs for crash symbolication. Development and Production iCloud data are separate; keep source entitlements on Development.
- Update existing docs when behavior changes. Keep release status in `testflight.md` and detailed test output under ignored `build/`.
