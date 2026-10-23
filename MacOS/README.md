# Native macOS app

BoraMinMac is an AppKit/SwiftUI app targeting **macOS Sequoia 15.0+**. The current build is **Apple Silicon (arm64)**. It is not Catalyst. The existing SMB, caching, container parsing, hardware video, audio resource loader, preferences, Keychain, favorites, Watching bookmarks and iCloud implementation are shared unchanged. Only the mobile/TV `BrowserScreen` is conditionally excluded on Mac.

The Mac interface uses `NavigationSplitView`, native `Table` rows and selection, system colors, toolbar navigation/search, a `Settings` scene and `AVPlayerView` in a resizable/full-screen `NSWindow`. Double-click opens folders or plays files; Control-click exposes Favorite/Remove Favorite and Reset Playback. Command-Up opens the enclosing folder, Command-R refreshes, Command-K opens Connection Setup, and Command-comma opens Settings. Favorites and Files maintain separate navigation state. There is no local-file opening feature.

Playback retains the existing routing: native AVPlayer video/track controls for supported native containers; existing FFmpeg demux/audio plus Apple's video APIs for MKV/VP9. The existing sample-buffer layer uses AVPlayerView's public `contentOverlayView`. AVKit supplies all transport/full-screen controls. No custom MKV track selection or remux-default change is added.

The bundle identity is now `com.example.BoraMin`, matching iOS/tvOS for a single App Store Connect record. This supersedes the initial Mac prototype's `.macOS` ID. The old sandbox/preferences are not automatically migrated; the existing shared development CloudKit container can restore synced data. No old app or local data is deleted.

## Build

```sh
python3 tools/build_ffmpeg.py --platform macos
python3 tools/create_project.py
xcodebuild -project BoraMin.xcodeproj -scheme "BoraMin macOS" \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/macOS -allowProvisioningUpdates build
open build/macOS/Build/Products/Release/BoraMin.app
```

FFmpeg is pinned to the same minimal LGPL build used by iOS/tvOS, statically linked, with no software video decoders. No Homebrew runtime libraries are required by the app. Generated macOS FFmpeg headers/libraries are ignored in git. Signing requires a registered development Mac and a provisioning profile for `com.example.BoraMin` with the existing `iCloud.com.example.BoraMin` container. Device registration was explicitly approved for the current Mac.

The app is sandboxed: outbound SMB and the existing loopback streaming listener are enabled; no broad filesystem access is granted. Server details are user preferences and passwords live in Keychain; no credentials or addresses are embedded in the build. iCloud uses the existing private database and encrypted credential records. The Mac delegate registers for remote notifications and requests sync on notifications/activation.

## Verification (October 22, 2026)

- Signed Release build launches on actual **macOS 15.7.4**. Signature verification passes, minimum OS is 15.0, and linked dependencies are Apple/system libraries only.
- The app imported connection details and alphabetically ordered Favorites through iCloud, automatically connected to SMB, and Settings reported **Up to date**.
- Observed actual 3840×2160 59.94 fps VP9 HDR fixture VP9 video over SMB in the native Mac player, with hardware decoding confirmed. The native timeline sought forward to 90 seconds and playback continued. The final Release build also resumed the saved position near the end, displayed video, closed the player on completion and cleared its bookmark. Back returned to Favorites; switching to Files preserved its separate share-list location. A transient “No route to host” during a Release launch cleared on Retry; the server was reachable from the Mac. The debug cache remained bounded at 128 MiB.
- `python3 tools/run_tests.py` passes: persistence, Favorites, Keychain, packet identity, random PCM reads, keyframe seeks, cancellation, all 600 VP9 frames with confirmed hardware, H.264 B-frames, HEVC Main 10 and renderer drain markers.
- `tools/test_macos_playback.sh` exercises the actual Mac window adapter using disposable MP4/MKV inputs: real native MP4 pixel buffers, two native audio options and native subtitle options, distant forward/backward seeking, pause/resume, consecutive player windows, cleanup and automatic window dismissal at completion. macOS exposed four native subtitle options for the fixture's two language tracks; the check allows the system's additional options. These test inputs do not add local-file opening to the app.

The Mac adapter probe generates its disposable MP4/MKV fixtures when missing and requires command-line FFmpeg for fixture generation. The existing full regression script generates and tests its own temporary codec fixtures.

Limitations: Intel builds are not produced yet; native codec/track support remains dependent on AVFoundation; MKV still uses its first audio track and has no subtitle selection, matching the current other-platform pipeline. Hardware VP9 depends on the Mac's VideoToolbox capabilities. The build is development-signed, not notarized for public distribution. No iPhone or Apple TV was deployed to or tested during this work.

## TestFlight distribution

The Production schema is deployed; the normal development build remains on Development. See [Production setup and validated Mac export](../docs/TestFlight.md) for the standard archive/export workflow and remaining TestFlight checks.
