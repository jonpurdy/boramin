# BoraMin for macOS

Native AppKit/SwiftUI app for **macOS Sequoia 15.0+**, currently Apple Silicon arm64 only. It is not Catalyst. Use **BoraMin.xcodeproj → BoraMin macOS**.

The interface uses NavigationSplitView, native tables/selection, toolbar navigation/search, a Settings scene, and resizable playback windows with system full-screen support. Double-click opens folders/videos; Control-click opens context actions. Files and Favorites retain separate navigation. There is no local-file opening feature.

| Shortcut | Action |
| --- | --- |
| Double-click playback content | Enter full screen |
| Space (playback window) | Play / pause |
| Left / Right (playback window) | Seek backward / forward 10 seconds |
| Command-Up | Enclosing folder |
| Command-R | Refresh |
| Command-K | Connections |
| Command-comma | Settings |

SMB, caching, bookmarks, credentials, iCloud, and playback engines are shared. Native sessions use AVPlayerView, and separately rendered video follows its overlay size in windowed and full-screen playback; software sessions use the shared fallback controls. Audio and Subtitles open separate popovers. Current routing and limitations are in the [main README](../README.md), [AetherEngine guide](../docs/AetherEngine-playback.md), and subtitle guides.

## Build

```sh
python3 tools/build_ffmpeg.py --platform macos
python3 tools/create_project.py
xcodebuild -project BoraMin.xcodeproj -scheme 'BoraMin macOS' \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/macOS build
open build/macOS/Build/Products/Release/BoraMin.app
```

Configure development signing/provisioning for the Mac and shared iCloud container. The sandbox allows outbound SMB and the engine's loopback listener; it does not grant broad filesystem access. Passwords live in Keychain; no server defaults are bundled. Dependencies are bundled rather than loaded from Homebrew at runtime.

See [Tests/README.md](../Tests/README.md) for isolated probes, [iCloud design](../docs/iCloud-sync.md) for sync boundaries, and the [archive helper](../tools/prepare_testflight.py) for distribution preparation. A development build is not a notarized public distribution.
