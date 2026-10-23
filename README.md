# BoraMin

A native SMB video player for Apple TV, iPhone/iPad and Mac. Browse shares, save favorites, resume unfinished videos and sync your library details through iCloud. Playback uses Apple's standard AVKit controls.

| Platform | Minimum OS | Xcode project / scheme | Bundle identifier |
| --- | --- | --- | --- |
| Apple TV | tvOS 26.6 | `BoraMin.xcodeproj` / `BoraMin tvOS` | `com.example.BoraMin` |
| iPhone / iPad | iOS 26.0 | `BoraMin.xcodeproj` / `BoraMin iOS` | `com.example.BoraMin` |
| Mac | macOS Sequoia 15.0 | `BoraMin.xcodeproj` / `BoraMin macOS` | `com.example.BoraMin` |

One Xcode project contains three native targets; there are no separate iOS/Mac projects. Current builds target physical Apple devices / Apple Silicon (arm64), without simulator or Intel slices. All three apps use the shared bundle identity from `tools/app_identity.py` for one multiplatform App Store Connect record. See [iOS notes](iOS/README.md) and [Mac notes](MacOS/README.md).

## Using the app

The main screen provides **Files**, **Favorites**, **Watching** and **Settings**; Mac presents these through its native sidebar and Settings window. Media comes from your SMB server/NAS. No media is included, and the Mac app does not add local-file opening.

- **Files** automatically connects to your saved SMB server. On first use, enter a hostname/IP (optionally `smb://` and a port), username/password and optional domain. An empty username means guest. Leave Share empty to enumerate shares, or specify one when enumeration is unavailable. Edit the connection under **Settings → Connection Setup**. No server or credentials are embedded in builds.
- **Favorites** stores server/share/folder paths alphabetically. Press and hold Select on Apple TV, touch and hold on iOS, or Control-click on Mac to add/remove a favorite. Files and Favorites keep separate navigation state; Back at a favorite's root returns to Favorites.
- **Watching** lists unfinished videos by most recent saved position. Filenames show `(80%, 00:12:45)` progress prefixes. Playback checkpoints every 15 seconds and saves on pause/exit; reopening resumes near that position. Completion clears the bookmark and closes playback. **Reset Playback** clears it manually. History is bounded to 500 active bookmarks.
- Files and folders sort together using natural alphabetical order. Dotfiles stay hidden. **Display all files**, off by default, adds other file types to the listing; playable extensions are `mp4`, `m4v`, `mov`, `mkv`, `webm`, `avi`, `ts` and `m2ts`. The extension filter does not guarantee codec compatibility.
- **Show Debug Info**, off by default, displays network payload speed, compressed-cache usage, source resolution/fps and decoder status. White caption text uses a translucent black backdrop. A five-second decoder label also appears at playback startup.

TV/iOS browsing uses black backgrounds and native selection/context menus. iOS playback opens in landscape; native AVPlayer video supports Apple's fit/fill pinch gesture. Mac uses a native sidebar, file tables, Settings window, keyboard shortcuts and resizable/full-screen AVKit playback. Demuxed MKV/VP9 video remains aspect-fit.

## Playback and limits

Supported native containers/codecs normally play directly through AVPlayer (VP9 takes the separate path described below), including its standard audio/subtitle selection for tracks AVFoundation exposes. Native playback uses AVPlayer’s automatic forward buffering and stall recovery; the separate demuxed audio timeline retains its existing bounded buffering configuration. Audio codec availability does not guarantee support for every profile; see the [AAC compatibility investigation](Tests/Native-audio-compatibility.md). Sidecar SRT/VTT selection is not implemented.

MKV/WebM, and VP9 regardless of container, use the FFmpeg demux/audio pipeline with Apple's video APIs and a separate sample-buffer video layer, while AVKit provides the controls. H.264, HEVC and other integrated system-supported video codecs can play without video re-encoding. VP9 requires a hardware VideoToolbox session and verifies hardware use. Other playback displays **System Decoding (HW/SW unknown)** because the app does not confirm hardware/software selection for those paths. No FFmpeg software-video decoder fallback is bundled; this does not imply that every Apple system decoder uses hardware. Hardware VP9 depends on OS/device support; iOS supplemental VP9 registration requires iOS 26.2+.

The compressed SMB cache defaults to a 128 MiB capacity per active stream across formats/platforms. This is not a cap on total app memory: decoded frames, audio and system-player buffers use additional memory. Streaming reads metadata and requested ranges without downloading the whole movie. Demuxed playback decodes requested audio windows to stereo PCM and uses the native audio timeline to drive the sample-buffer video layer. For the demuxed iOS/tvOS path, the AVKit seek delegate snaps scrubbing to the nearest available indexed keyframe; saved-position resume starts at a preceding keyframe. Native MP4/MOV seeking remains controlled by AVPlayer. Demuxed index discovery allows at most 4 MiB of additional reads. Files without useful indexes can seek slowly. Cancellation stops the streaming listener/readers; pending SMB requests may remain until their timeout.

MKV uses one audio track automatically selected by FFmpeg and has no selectable subtitles. MKV audio/subtitle selection and a bundled software-video fallback remain deferred. The **opt-in** `--experimental-vp9-remux` prototype copies VP9/AAC into bounded on-demand fMP4/HLS for native AVPlayer rendering; it is not the production default. Keep its [results and limitations](Tests/Streaming-remux-investigation.md) in mind before further integration. The demuxed path can also trigger tvOS’s system Now Playing banner (“To open player, hold…”); suppression remains deferred.

## App identity

All app targets use `com.example.BoraMin`; the existing CloudKit container stays `iCloud.com.example.BoraMin`. Earlier builds used `com.example.BoraMin` on Apple TV, with `.SyncTest` and `.macOS` suffixes on iOS and Mac. Installing a build with the shared `com.example.BoraMin` ID creates a distinct local app identity on every platform; it does not upgrade the old prototype's preferences, sandbox or Keychain access group. The old apps/data remain intact. Saved data can be restored from the same iCloud account/container/environment after sync; settings kept only locally may require re-entry. No migration through private APIs or old-container access is implemented.

Development builds still select CloudKit **Development**. Unifying bundle IDs does not change the CloudKit environment or copy records into Production. The Production CloudKit schema was deployed on October 22, 2026, without copying development records. The [TestFlight export workflow](docs/TestFlight.md) explicitly selects Production during distribution signing; end-to-end TestFlight sync validation remains to be done.

## iCloud and credentials

**Sync via iCloud** is on by default. It merges connection profiles, encrypted credentials, favorites, playback positions/resets, Watching metadata, Display all files and Show Debug Info in the private `iCloud.com.example.BoraMin` container. Local passwords live in device-only Keychain; ordinary preferences and the durable sync queue exclude passwords. Navigation state, playback sessions and the sync switch remain local.

The shared CKSyncEngine implementation fetches before merging/sending, retains versioned reset/removal states, and queues edits while offline or sync is disabled. Launch/foreground and important edits request sync; ordinary playback checkpoints are coalesced. Important edits are normally scheduled after about one second, ordinary position updates after about 45 seconds, and failed syncs retry after about 60 seconds while the app can run. Lifecycle/manual requests can trigger an earlier sync; these are scheduling delays, not delivery guarantees. Delivery is asynchronous. Settings shows sync status and a manual Sync Now action. Account changes pause sync to avoid mixing users; Apple TV profile switching is not implemented. Normal Xcode development builds use CloudKit's Development environment; TestFlight/App Store distribution uses Production signing and the deployed Production schema. See [sync design and caveats](docs/iCloud-sync.md).

Development and Production have separate records and do not sync with each other. No data-transfer feature is implemented. Replacing a development build with TestFlight is not a supported migration: the current local sync metadata is not separated by environment. Keep development testing separate from your production library; use a deliberate migration if existing development data must be preserved.

## Building

Requires Xcode, Python 3, make and network access for the checksum-verified FFmpeg source download. AMSMB2/libsmb2 are vendored; generated FFmpeg libraries are ignored. The same pinned minimal LGPL FFmpeg build supplies demuxing/audio, with no video software decoders. The apps have no Homebrew runtime dependency. Preserve the [dependency notices](vendor/DEPENDENCIES.md) when distributing.

Generate the shared project, then build the platform libraries and scheme you need. FFmpeg only needs rebuilding when its generated libraries are missing or its build configuration changes:

```sh
python3 tools/create_project.py

# Apple TV
python3 tools/build_ffmpeg.py --platform tvos
xcodebuild -project BoraMin.xcodeproj -scheme "BoraMin tvOS" -configuration Release \
  -destination 'generic/platform=tvOS' -derivedDataPath build build

# iPhone / iPad
python3 tools/build_ffmpeg.py --platform ios
xcodebuild -project BoraMin.xcodeproj -scheme "BoraMin iOS" -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/iOS build

# Mac
python3 tools/build_ffmpeg.py --platform macos
xcodebuild -project BoraMin.xcodeproj -scheme "BoraMin macOS" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/macOS build
```

Project regeneration preserves per-target development team, version/build numbers and compatible provisioning-profile choices. Keep project structure/build-setting changes in `tools/create_project.py` so regeneration retains them.

Choose your development team/provisioning in Xcode for signed builds and iCloud. Add `CODE_SIGNING_ALLOWED=NO` for a compile-only check, or `-allowProvisioningUpdates` when provisioning updates are authorized. The installed Xcode 26.3 has SDK 26.2 and warns about the requested tvOS 26.6 deployment target; that is not a claim to have built against a 26.6 SDK.

## TestFlight

Follow the [routine TestFlight build and Organizer upload guide](testflight.md).

iOS and tvOS **0.1 (1)** uploaded successfully through Xcode Organizer on October 22, 2026, using **App Store Connect** distribution, which supports external testing. The required tvOS Top Shelf assets are included. Upload success does not establish completion of processing, export compliance or beta review; external availability has not been confirmed. The reported **Missing Compliance** questionnaire still needs to be completed based on the bundled SMB cryptography.

For another beta, choose a new build number, archive the requested schemes, then use **Organizer → Distribute App → App Store Connect**. When asked to control Xcode/Organizer, follow the actual UI workflow in the guide. Building alone does not archive/upload, and uploading does not install on devices or invite testers.

The Production schema is deployed. Alternatively, `python3 tools/prepare_testflight.py PLATFORM --export --build-number N` creates an archive and a local distribution with Production iCloud entitlements; replace `PLATFORM` with `ios`, `tvos` or `macos` and `N` with the next appropriate build number. It does not upload. The helper reuses its archive output path, so preserve archives needed for previous releases. See [release preparation and verification](docs/TestFlight.md).

## Tests and investigations

Playback and streaming diagnostics use Apple’s unified `Logger`, with subsystem `com.example.BoraMin`. Lifecycle, player-state, decoder/error and periodic memory/cache entries help investigate unexpected exits. See [collecting playback logs and crash reports](docs/Diagnostics.md); these logs are separate from the on-screen debug overlay and are not automatically attached to TestFlight crash reports.

```sh
python3 tools/run_tests.py          # Host persistence, demux/audio, keyframes, hardware VP9 and native codec checks
python3 tools/test_streaming_remux.py # Opt-in remux packet/timestamp regression
# After building macOS FFmpeg libraries:
tools/test_macos_playback.sh         # Actual Mac AVKit adapter, frames, selections, seeks and lifecycle
```

Host test tools require command-line FFmpeg/Homebrew development libraries and the adjacent `atv vp9-av1 testing` fixtures; they do not establish iPhone/Apple TV playback quality. The Mac adapter probe generates disposable local test media, without adding local-file opening to the app.

Reusable device smoke-test flags and isolated probes are documented in [Tests/README.md](Tests/README.md). Normal app builds exclude the synthetic CloudKit test screen. Test launches can edit playback history unless `--no-playback-history` is supplied; normal launches perform no test actions.

Keep these records for future codec work:

- [Verification history](Tests/verification.txt)
- [VP9 streaming/cache investigation](Tests/VP9-streaming-investigation.md)
- [Native VP9 compatibility](Tests/Native-VP9-investigation.md)
- [Streaming remux results, GMPlayer comparison and limits](Tests/Streaming-remux-investigation.md)
- [Native AAC compatibility](Tests/Native-audio-compatibility.md)

## Repository layout

- `BoraMin.xcodeproj`: shared native iOS, tvOS and macOS targets and schemes.
- `testflight.md`: routine beta build, Organizer upload and tester-group instructions.
- `Player/`: shared SMB/browser models, transport/demux/decoder code and iOS/tvOS browser/player views.
- `Shared/`: production iCloud sync.
- `iOS/`: native iOS application entry, entitlements and platform notes.
- `MacOS/`: native Mac interface and AVKit adapter.
- `Assets/`: editable Icon Composer asset and tvOS layered icon catalog. `Assets/BoraMin.icon/Assets` contains the authoritative icon layers; `boramin-icon.png` is the original artwork. The Mac app has a standard icon catalog. tvOS includes standard and wide static Top Shelf assets; regenerate them from the existing layered artwork with `swift tools/create_tvos_topshelf.swift "$PWD"`.
- `Tests/`, `docs/`, `tools/`: regression fixtures/probes, investigation notes and build/test helpers.
- `vendor/`: dependency sources/notices and ignored generated FFmpeg libraries.

`build/` contains ignored products, diagnostics, generated media and helper-created archives/exports. Preserve release archives and dSYMs needed for crash symbolication before cleaning it or overwriting an archive. Xcode Organizer archives are normally stored separately under Xcode’s user Archives directory. Local `default_*.txt` files are ignored and never read or bundled by the apps or project generators.

### Native SMB playback

MP4, M4V and MOV streaming uses AVFoundation's resource-loader API on iOS, tvOS and macOS. The loader serves unchanged bytes through the existing 128 MiB SMB cache; AVPlayer handles parsing, decoding, controls, audio/subtitle selection and gestures. Files are not downloaded or remuxed first. Other native formats retain HTTP loading; MKV/WebM retain their existing demuxed playback path. Native playback selects the first supported audio option and reports an error if audio exists but none is supported.
