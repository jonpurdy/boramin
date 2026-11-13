# Working on BoraMin

- Use supported public APIs and native platform controls. Ask before introducing new custom playback/UI integrations; existing approved integrations may be maintained.
- Share code where practical, while keeping each platform's interface native. Do not change playback routing or add local-file imports incidentally.
- Keep changes focused. Preserve unrelated work and leave `_to do.txt` alone.

## Code and builds

- `Player/`: shared browsing/playback and iOS/tvOS screens. `Shared/`: iCloud. `iOS/`, `tvOS/`, and `MacOS/`: platform code/configuration. `tvOS/TopShelf/`: the tvOS Top Shelf extension, with `TopShelfSnapshot.swift` shared by the tvOS app and extension targets.
- Keep navigation and presentation in `Browser.swift` and the platform screens. Route remote operations through `RemoteSession.swift`, with SMB operations in `SMBBrowsingService.swift` and HTTP operations in `HTTPFileService.swift`. Keep metadata reads in `MetadataProbeService.swift` and opt-in browser probes in `BrowserDiagnostics.swift`.
- Use `BoraMin.xcodeproj` and its three platform schemes. Keep project-definition changes in `tools/create_project.py`; regenerate only when needed. See `README.md` for prerequisites and supported targets.
- Keep signing and runtime identifiers in the ignored `Config/Identity.local.xcconfig`. Use the checked-in example for setup, and preserve existing identifier values when building for an existing installation. Set release versions and build numbers through the project generator.
- Mac supports Apple Silicon; current dependencies do not include simulator/Intel slices. Do not silently lower deployment targets to work around SDK warnings.
- Regenerate Mac icons with `swift tools/create_macos_icon.swift`, using the shared Icon Composer artwork. Preserve real transparency.
- Preserve the private `BoraMinMedia` framework boundary: its FFmpeg symbols must not override AetherEngine's. Use `tools/verify_media_linkage.py` when changing media linkage.
- Do not replace ordinary SMB cache locking with timed `try()` polling: that caused confirmed hardware VP9 stutter. See `Tests/VP9-streaming-investigation.md` before changing this path.

## Behavior to preserve

- HTTP browsing uses JSON directory listings from Caddy or nginx. Keep HTTP read-only, validate bounded `206 Partial Content` responses, and reject redirects that leave the configured origin or base path. Never fall back to a whole-file GET.
- Keep **Speed test…** in file context menus. Use a separate cancellable session that bypasses the playback cache and stops at EOF, 2048 MiB, or about ten seconds of reading. Keep SMB deletion preflight checks and preserve subtitle sidecars that match another video.
- Keep hardware VP9 on its VideoToolbox route and preserve native AVKit controls where supported. File-row route labels are predictions. See [AetherEngine playback](docs/AetherEngine-playback.md) for fallback behavior and [subtitle support](docs/subtitles.md) for track matching and rendering.
- Keep saved connection IDs stable. Scope Keychain credentials by connection ID and preserve Watching and Favorites references across connection edits and sync. Unchanged checkpoints should leave Watching order intact. See [iCloud sync](docs/iCloud-sync.md).

## Validation and delivery

- Build affected platforms and run relevant checks. The main suite is `python3 tools/run_tests.py`; offline browser checks are `python3 tools/run_playback_probe.py browsing offline` and `python3 tools/run_playback_probe.py cancellation offline`.
- Use `python3 tools/run_tests.py --offline` when live SMB and HTTP fixtures are unavailable. Keep private fixture paths and profile IDs in the ignored `Config/PlaybackFixtures.local.json`.
- Run playback probes sequentially: they share a generated project/product. See `Tests/README.md`. Remove the generated diagnostic app afterward to avoid duplicate BoraMin copies; retain useful logs.
- Report what was actually verified. Compilation or an advancing audio clock does not prove visible video playback. Do not interrupt device playback unless requested.
- Never bundle or print credentials. Ignored `default_*.txt` files are local-only and must remain unused by app builds. Do not modify source media while debugging playback.
- Follow personal TestFlight notes in the ignored local folder when available. Use `tools/prepare_testflight.py` for local archive and export preparation. Upload only when requested; preserve archives/dSYMs for crash symbolication. Development and Production iCloud data are separate; keep source entitlements on Development.
- Update existing docs when behavior changes. Keep personal release status in the ignored local folder and detailed test output under ignored `build/`.
