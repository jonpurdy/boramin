# BoraMin for Apple TV

Bundle identifier: `com.example.BoraMin`.

tvOS **26.6** MVP: automatically connect to a saved SMB2/3 server, enumerate its shares, browse folders, select a video and play it with **AVPlayerViewController's standard controls**. Original VP9 compressed video goes through a hardware-required VideoToolbox session. No custom transport buttons or scrubber.

## Run

1. Open `BoraMin.xcodeproj` in Xcode. Choose your development team under Signing & Capabilities.
2. Select a physical Apple TV running tvOS 26.6 or newer, build and run the shared BoraMin scheme.
3. Choose **Files** on the home screen. It connects automatically using your saved server details. On first use, enter the server's hostname/IP (optionally `smb://` and a port), username and password. Empty username means guest. Domain is optional. You can edit these details later in **Settings → Connection Setup**.
4. Leave Share empty to enumerate shares, or enter a known share when the server denies enumeration. Open folders and choose a video. Playback streams directly from SMB after reading the metadata and a small initial buffer.
5. Use the native player to pause, seek and change playback speed; use Back/Menu to dismiss. The browser's Parent folder/Back buttons navigate folders and shares.

The black home screen has SF Symbol buttons with color-only focus feedback (no enlargement or hover effect), charcoal (`#202020`) unfocused backgrounds and white content, and near-white focused backgrounds with black content. The home screen has no title above the tiles. The home screen has buttons for **Files**, **Favorites**, **Watching**, and **Settings**. On tvOS, tiles, SF Symbols, labels and spacing use 65% of the original size. Native navigation headers use white text on a transparent bar over the black background. Files and Favorites have separate browsing sessions: opening or navigating a favorite never changes the server, share or folder last visited in Files. In Files, press and hold Select on a folder or share to open its standard context menu and choose **Favorite**. Favorites saves unique server/share/folder locations in local UserDefaults, without passwords, and lists them alphabetically. Selecting one reconnects using the saved connection credentials and opens that folder directly. Back navigates up through folders/shares in Files. When opened from Favorites, Back at the saved folder returns directly to Favorites; deeper subfolders navigate up to that saved folder first. Dotfiles stay hidden, files and folders sort together, and playback progress prefixes do not affect sorting.

Press and hold Select on a video and choose **Reset playback** to clear its saved position. Its percentage/time prefix disappears immediately, and the next playback starts at the beginning. The action is disabled when the video has no saved position.

With **Sync via iCloud** enabled, installations restore connection details from the signed-in iCloud account. Otherwise connection fields start empty. Enter the server, username, password and optional domain/share once in Files, then connect. After a successful connection, server/username/domain/share are saved in UserDefaults and the password is stored in the local, device-only Keychain, scoped to server/port/account/domain. Files connects automatically on subsequent visits, including the saved Keychain password. Folder browsing and playback check the SMB session and reconnect when it has expired; returning to Files from the background refreshes the current listing. Temporary network failures retry every ten seconds while the browser is open, preserving the current share/folder. Missing details or rejected credentials show setup instead. **Settings → Connection Setup** always provides manual editing. Leaving setup without connecting discards edits, and failed edits keep the previous working connection. Reconnecting a favorite does not replace the saved Files connection. No default credential or server files are read or bundled, even if local `default_*.txt` files exist. Favorites reuse the saved credentials. No server address or password is included in the app build. iCloud uses the encrypted private CloudKit database; passwords remain in local Keychain and are never written into the sync queue.

The installed toolchain is Xcode 26.3 / tvOS SDK 26.2. The project and compiled dependencies deliberately set deployment target 26.6, as requested. Xcode warns that its SDK is older than that deployment target. This does not mean it was compiled against a 26.6 SDK. Use a newer toolchain when available. Only **physical arm64 tvOS** is built; these static libraries do not include simulator slices.

## VP9 and native controls

This uses the finding and physical-device evidence from the adjacent `atv vp9-av1 testing` project:

- Call `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)` once before session creation. This API is public on tvOS 26.2+.
- Require `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder` and check `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`. Session creation and decode errors are surfaced; there is no software VP9 video decoder or silent fallback.
- Read profile, bit depth, dimensions, range and subsampling from the original VP9 keyframe header. Do not infer 8-bit from an unknown FFmpeg pixel format: the minimal tvOS library has no software VP9 decoder to populate that field during stream probing. The Mac control now also forbids software video probing so this difference cannot be hidden by Homebrew's extra decoders. Set the source vpcC level (or derive its picture-size/sample-rate level) and explicitly request 8-bit NV12 or 10-bit P010 output.
- Demux original packets from MP4/Matroska/WebM with a small FFmpeg C bridge. Preserve timestamps, source color signalling and static HDR mastering/content-light metadata. Support VP9 8-bit Profile 0 and 10-bit Profile 2, 4:2:0.
- Decode into an AVSampleBufferDisplayLayer in the native controller's content overlay. Bind its control timebase directly to the AVPlayer item's timebase. AVPlayer owns the audio and timeline. Its controls drive pause/rate/seek; a time-jump notification flushes and restarts VP9 from a preceding keyframe.
- Bound decoded video read-ahead to about 400 ms. Decode dependencies but omit presentation of frames already expired. Request source frame-rate/dynamic-range display criteria while the player is open; actual output depends on Apple TV Match Content settings and the display.

An audio-only CAF timeline lets the native controller control hardware-decoded VP9 without assuming AVPlayer can open a VP9 container. For VP9, the first audio track is decoded/resampled on demand to stereo 48 kHz signed 16-bit PCM. An AVAssetResourceLoader delegate serves requested sample ranges to AVPlayer; video-only files receive generated silence. Neither the movie nor a full PCM file is written to storage. AAC, Opus, Vorbis, AC-3, E-AC-3, FLAC, MP3, ALAC, common integer PCM and DTS audio decoders are built. This is **stereo audio**, with no Atmos/bitstream passthrough or track switching.

Other video codecs use the same SMB byte-range source through a loopback-only HTTP endpoint with AVPlayer. Their container/codec must be supported by native tvOS playback. For example, H.264/HEVC MP4/MOV are expected paths; H.264 MKV is **not** remuxed by this MVP and may fail. A listed file extension is not a guarantee that every codec combination in that container works. Unsupported media reports an error.

## Streaming and interface

- SMB reads use a shared **128 MiB in-memory block cache** for all streaming formats on iOS and tvOS, with exact-length range checks. FFmpeg custom AVIO callbacks provide random reads and seeks directly from that cache; FFmpeg network protocols remain disabled.
- AVPlayer-compatible formats stream from a loopback HTTP range endpoint. VP9 uses an AVAssetResourceLoader delegate for on-demand CAF audio, with the hardware video decoder bound to the same native player's clock. The synthetic audio advertises independent random-access availability (`isEntireLengthAvailableOnDemand`); otherwise tvOS's progressive parser can block its media service during a seek.
- Only requested audio windows are decoded. Each new native loading request can preroll its first five seconds before the clock moves; larger progressive requests then follow the playback clock. AVFoundation cancels stale resource-loading requests at native seeks. Video restarts at a preceding keyframe on time-jump notifications or a detected discontinuity in that clock, including paused seeks whose notification is delayed.
- Audio seeks use the indexed video track for container positioning. Seeking an unindexed audio track in Matroska can otherwise scan much of the movie. Files without a useful index can still be slow to seek.
- Native VP9 scrubbing snaps to the nearest indexed keyframe, trading exact positioning for faster video startup. Index discovery is bounded to 4 MiB of streamed reads; an unavailable or incomplete index preserves exact seeking. Timestamp conversion rounds to the container timebase so a fractional keyframe timestamp does not accidentally select its predecessor. Video retains the last displayed picture while preparing the new position, and duplicate pending seek notifications are coalesced.
- Browsing, connection, loading and player backgrounds are solid RGB **0, 0, 0**. System focus highlights and Apple's native playback controls retain their standard appearance.
- A noninteractive top-right label uses AVPlayerViewController's standard content overlay for five seconds after playback starts. VP9 displays **Hardware Decoding** only after the hardware-required session produces a frame. Other formats display **System Decoding (HW/SW unknown)** because AVPlayer does not expose its selected decoder through a public API. The app currently has no software-video decoder path, so it does not claim **Software Decoding**. Seeking does not restart the label timer.
- Startup and seeks require metadata, codec preroll and network buffers, not the entire movie. No offline download cache or free-space requirement for a full movie/PCM timeline remains in normal SMB playback.
- Dismissal and cancellation stop readers, close the loopback listener and release the cache. Pending SMB calls may take until the client timeout to finish in the background. Native buffering and TV HDR/Match Content settings still affect playback.
- Local resume positions use UserDefaults, keyed by a hash of the SMB server/port, share, full path and file size. Exit and backgrounding save the current position; playback also checkpoints every 15 seconds. Reopening restores it before playback begins (at the preceding VP9 keyframe, so nothing unwatched is skipped). Reaching the end clears it. The store retains the 500 most recently updated bookmarks. Bookmark keys remain hashes; a separate bounded metadata store records the SMB server, share, filename/path, size and account/domain for Watching, without passwords.
- Files with saved positions show `(80%, 00:12:45) Filename.mkv` in the list, using the saved duration for the percentage. This requires no extra media probes while browsing; original filenames still determine alphabetical sorting. Completed files return to plain filenames.
- No subtitles, posters/library, automatic discovery, multi-audio selection, Atmos passthrough or AV1 software path yet. Non-VP9 containers/codecs still need native tvOS support; H.264 MKV is not remuxed by this MVP.

## Build dependencies

AMSMB2 4.0.3 and its pinned libsmb2 source are in `vendor/AMSMB2`. The local package is adjusted to build statically without upstream test dependencies, so app builds need no Swift package network access.

Generated FFmpeg libraries live in ignored `vendor/ffmpeg`; rebuild them on a fresh checkout:

```sh
python3 tools/build_ffmpeg.py
python3 tools/create_project.py
xcodebuild -project BoraMin.xcodeproj -scheme BoraMin -configuration Release \
  -destination 'generic/platform=tvOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

The dependency helper verifies the pinned source archive's SHA-256 and builds only container/audio libraries, with no video software decoders. It requires network access, Xcode command-line tools and make. The project generator preserves development-team and bundle-identifier choices saved in the project. See `vendor/DEPENDENCIES.md` for versions and license notes.

## Verification

`Tests/BridgeTests.c` covers missing input, source metadata, original packet extraction, keyframe seeking, video-only silence, Opus audio preparation and cancellation. `Tests/StreamingTests.c` checks custom range IO, partial-file startup, exact sequential PCM, random audio seeking and cancellation. `Tests/StreamingProbe.swift` exercises a real SMB source, HTTP HEAD/middle/suffix ranges, 404/416 responses, native CAF resource loading and seek-aware audio reads against a temporary read-only localhost share. `Tests/PlaybackProbe.swift` uses the app's format/session code to confirm hardware and decode all 600 frames of the adjacent project's source clip, and checks the prepared CAF with AVFoundation. These Mac controls do not establish Apple TV playback quality.

`python3 tools/run_tests.py` runs those checks using Homebrew FFmpeg on this Mac. The hardware control requires access to the system decoder services; a sandbox may reject decoder creation.

Verified October 17, 2026: signed Release tvOS build succeeds; all 600 original VP9 payloads match the lab fixture; all 600 frames decode on this Mac with hardware confirmed; Opus-to-PCM output matches FFmpeg byte for byte; prepared CAF is playable through AVFoundation. The same SMB client successfully enumerates a temporary read-only SMB2 share, browses a nested folder with a Unicode/space-containing filename, and downloads a file whose SHA-256 matches the source. That test server rejects clean logoff after transfer; the browser handles teardown as best effort.

Initial CoreDevice pairing/deployment failures were resolved; the final app subsequently installed and launched on the Apple TV. Apple documents that tvOS has no separate Developer Mode switch, so the earlier CoreDevice 4011 message was not a request to enable one.

The reported `Decode VP9: OSStatus -12909` failure was reproduced as a metadata mismatch: minimal FFmpeg did not supply a pixel format, and the app incorrectly assumed 8-bit for a 10-bit Profile 2 stream. The app now parses the keyframe header directly and requests matching decoder output. All 9,506 frames in the exact original VP9 HDR fixture MKV decode on this Mac with hardware confirmed and software VP9 probing disabled. The corrected build also plays that exact MKV on the physical Apple TV with hardware confirmed; the user confirmed both video and audio. On-device decoding reached 5,100 frames / about 85 seconds before the user paused or left playback; it was not an uninterrupted full-duration device test. The normal build excludes the bundled diagnostic movie and retains user-entered connection settings. See `Tests/verification.txt` for the validation record.

For a physical-device smoke test, generate a temporary project with `BORAMIN_SMOKE_FIXTURE=/absolute/path/smoke.webm python3 tools/create_project.py`, build/install, then launch with `--smoke-test`. The resource must be named `smoke.webm`. Alternatively put that file in the app's Library/Caches directory. This legacy bundled-file diagnostic prepares local audio and uses the same native player, but does not test SMB streaming. Regenerate without that environment variable to remove the bundled fixture. Console records hardware confirmation, VP9 EOF/frame count and native playback completion. Normal launches show the BoraMin home screen.

For a real SMB streaming smoke test, launch with `--stream-smoke-test SHARE RELATIVE_PATH`. It uses the saved credentials without printing them. Add `--exercise-stream-controls` to exercise native pause and seeks to 90s and 20s on a sufficiently long file. Normal launches show the SMB browser, with no automated playback or control actions. See `Tests/verification.txt` for actual measured results and the distinction between local controls and physical-device tests.

With `--stream-smoke-test`, `--exercise-player-lifecycle` opens, plays, and dismisses the clip three times in one process through the real SwiftUI full-screen presentation. This guards against the second-video presentation crash. Playback payloads use immutable reference identity so SwiftUI does not recursively compare the imported C metadata and adjacent Swift arrays. Teardown is idempotent, and cancellation cannot surface a stale error from the dismissed player.

## Settings

**Display all files** is off by default and saved locally using AppStorage/UserDefaults. Browsing in Files and Favorites always includes folders; by default it shows only supported video extensions (`mp4`, `m4v`, `mov`, `mkv`, `webm`, `avi`, `ts`, `m2ts`). Enable the toggle to also see other files, which remain unavailable for playback. Dotfiles and dotfolders stay hidden. The filter updates existing listings without another SMB request.

## Sync via iCloud

**Settings → Sync via iCloud** is enabled by default. It synchronizes saved connection profiles (server/port, account, domain, preferred share and encrypted password), favorites, playback positions/resets and Display all files. The switch itself, navigation/focus state and sync diagnostics stay device-local. Turning sync off keeps local data and queues subsequent edits; re-enabling merges them with iCloud. Settings shows sync status, last success and Sync now.

`Shared/ICloudSync.swift` uses CKSyncEngine with the private container `iCloud.com.example.BoraMin`, zone `BoraMinUserData-v1`, and encrypted `BoraMinUserData` record fields. The generator retains CloudKit entitlements in `Config/BoraMin.entitlements`. These development-signed installs use CloudKit's Development environment; promote the schema and use production provisioning before App Store distribution.

Existing data is merged record by record after fetching the cloud, rather than replacing it with an empty first-run snapshot. Playback keeps 15-second local checkpoints and coalesces ordinary cloud updates; pause, exit, backgrounding and reset request prompt sync. Cloud delivery is asynchronous and doesn't seek a currently playing video. Reset/completion and removals use explicit versioned states so older offline edits do not resurrect cleared data. Local history remains limited to 500 active positions.

The full sync metadata is a recoverable cache. A bounded password-free outbox in preferences preserves pending changes across tvOS cache eviction; passwords are resolved from device-only Keychain when uploading and stored there after download. The TV currently uses its default iCloud account. Account changes pause sync to prevent mixing users; switching Apple TV profiles and migrating to per-profile cloud stores is separate work.

The [iOS app on test device](SyncTest/README.md) now uses the same browser, SMB streaming player and production stores. It supports Files, Favorites, Settings, native playback controls, hardware VP9, saved positions/resume and iCloud sync. The installed companion bundle identity is retained to preserve data. The earlier isolated synthetic probe remains available through its launch flags.

## App icons

`Assets/BoraMin.icon` is the editable Icon Composer asset for iOS, built from the supplied `boramin-icon.png`: the baked checkerboard and rounded background were removed, and the mark/play symbol became separate transparent foreground layers over a purple system gradient. `Assets/BoraMin-preview.png` is its exported default appearance. The tvOS asset catalog uses the same artwork in three layers (play, mark, background), with native parallax and small/large icon sizes.

## Playback orientation and Favorites

iOS standard video playback uses AVKit's built-in pinch gesture for fit/fill, starting in aspect-fit for each video. No custom zoom recognizer is installed. VP9 remains aspect-fit in its separate display layer.

When a video finishes on iOS or tvOS, the system playback-end notification clears its saved position and dismisses the player to the previous browser screen. Dismissal cannot recreate the completed bookmark.

Settings → **Show Debug Info** is off by default and syncs with other preferences when iCloud sync is enabled. When enabled before opening a video, a noninteractive middle-right panel shows SMB payload transfer speed (MB/s over roughly the last second), resident compressed cache usage/capacity (MiB), source resolution/frame rate, and decoder status. Small white caption text sits on a 65%-opaque black background. Network/cache values describe our SMB transport, including repeated reads, rather than encoded bitrate or buffered seconds; local test files show these as not applicable. VP9 hardware use is confirmed; AVPlayer hardware/software selection remains unknown.

On iOS, playback supports landscape left/right only and requests landscape for its full-screen presentation; leaving playback restores normal menu rotation. Menus continue supporting portrait. Press and hold a favorite on iOS or Apple TV to choose **Remove favorite**. Removal is persisted and syncs through iCloud. Favorites sort by displayed name using natural alphabetical order (for example, Folder 2 before Folder 10), including when records arrive from iCloud in a different order.

## Browser background scope

Black list styling is local to the browser. tvOS uses the public UIAppearance containment API scoped to its explicit `UIHostingController<BrowserScreen>`; there is no global UICollectionView background override or AVKit-specific exception. iOS hides each browser list's system backdrop with SwiftUI's `scrollContentBackground(.hidden)` over a black background. Native row focus/selection and playback controls retain their system styling.

## Watching

**Watching** sits between Favorites and Settings on tvOS and iOS. Its standard list includes every unfinished video with a saved position, newest **last-save timestamp** first. No exact open-time timestamp is recorded. Rows show the usual percentage/time prefix and filename, and selection reconnects to the original SMB location and resumes through the existing native player. Reset playback and completion remove the item from Watching. Its browser session is separate from Files and Favorites.

Video location metadata syncs in encrypted CloudKit records alongside the existing bookmark records; passwords stay in Keychain. Older bookmarks contain only a hash, progress and last-save time, so their filenames cannot be reconstructed directly. Watching attempts shallow reads of saved favorite folders to recover matching locations; browsing folders in Files/Favorites also recovers metadata without changing progress or sort time. Unresolved legacy bookmarks remain visible with a saved-video identifier and an instruction to open their folder. A changed file size requires reopening the file from Files to establish a new bookmark identity.

Optional VP9 performance diagnostics: add `--vp9-diagnostics` to a CLI smoke-test launch to log clock/video timestamps, fetched bytes, thermal state, and decoded/queued/late frame counts. Add `--no-playback-history` to `--stream-smoke-test` to start at zero and avoid changing saved playback positions. Neither flag changes decoder choice or buffering policy; normal launches omit them.

The [iPhone VP9 streaming investigation](Tests/VP9-streaming-investigation.md) records controlled cache experiments. Normal playback now uses the approved 128 MiB cache for all streaming formats on iOS and tvOS. Test-only cache/read-size overrides remain available; the proposed lock change has not been applied.
