# BoraMin for iOS

Native iPhone/iPad app targeting iOS 26.0+, built for physical arm64 devices. Use **BoraMin.xcodeproj → BoraMin iOS**. The app bundle ID is shared with tvOS and Mac.

The shared browser supplies Files, Favorites, Watching, Settings, SMB connections, and iCloud sync. Menus support portrait; playback opens landscape. Native AVPlayer sessions support fit/fill pinch zoom. Software and separate VP9 video surfaces have different gesture limits. Audio & Subtitles uses a sheet.

Playback routing, subtitle behavior, and dependencies are described in the [main README](../README.md) and [AetherEngine guide](../docs/AetherEngine-playback.md). Original hardware VP9 registration requires iOS 26.2+ and a capable device. This does not mean all MKV VP9 sessions use that route.

## Build

```sh
python3 tools/build_ffmpeg.py --platform ios
python3 tools/create_project.py
xcodebuild -project BoraMin.xcodeproj -scheme 'BoraMin iOS' \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/iOS build
```

Initial dependency resolution needs network access. Configure signing for a physical device; installation/launch requires an available unlocked device. The Icon Composer asset is `Assets/BoraMin.icon`.

Development and distribution use separate CloudKit environments in the shared private container. See [iCloud design](../docs/iCloud-sync.md) and the [archive helper](../tools/prepare_testflight.py).

Test-only sync probes are excluded from normal builds. Their setup and caveats belong in [Tests/README.md](../Tests/README.md), rather than the app's build instructions.
