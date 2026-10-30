# AetherEngine playback

Current integration guide for native and software AetherEngine sessions. See the root [README](../README.md) for overall routing, including the separate VP9 path.

## Routing and controls

- MKV uses AetherEngine automatically except VP9, which uses the original hardware decoder and native AVKit controls. There is no default-off MKV switch.
- Non-VP9 WebM and the other recognized fallback containers use AetherEngine. MP4/M4V/MOV and VP9 retain their existing routes.
- When the engine supplies an AVPlayer, attach that same player to AVPlayerViewController on iOS/tvOS or AVPlayerView on Mac. Do not create another player from its HLS URL.
- Software sessions use the public AetherPlayerSurface with approved app-written SwiftUI controls: play/pause, skips, seeking, tracks, and close. Controls hide after five seconds of inactivity.
- During preparation, AVFoundation's configuration rejection (-11829 with underlying CoreMedia -12848) retries once with AetherEngine's public `preferredDecodePath = .software`. This uses the existing surface and controls; it does not change the source file. Network failures do not trigger this retry. The route's name does not imply CPU video decoding: AetherEngine can still use VideoToolbox.
- Audio & Subtitles uses the shared iOS sheet, Mac popover, or tvOS system menu. Source audio switching calls the engine's public API; replacement players/items require rebinding clock, completion, error, and track observers.
- Prefer existing AAC/AC-3/E-AC-3/ALAC/MP3 source audio, respecting defaults among these. Other audio may require engine conversion. Showing multiple source tracks does not imply AVKit receives multiple native renditions.
- External text subtitles and embedded ASS/SSA use libass. Other embedded subtitles retain native or existing overlay handling. See [styled ASS](Styled-ASS-subtitles.md) and [external subtitles](External-subtitles.md) for rendering, sizing, persistence, and limits.

Software playback saves progress every five seconds and on close; completion clears progress and dismisses. iOS opens landscape, and Mac uses a resizable full-screen-capable window. Backgrounding software playback saves/stops and returns to browsing.

## SMB and buffering

`Player/AetherMKVPlayback.swift` adapts the existing SMB source to AetherEngine's public IOReader protocol. Independent cursors share the 128 MiB compressed cache. Size queries and bounded byte seeks are supported; cancelling a probe must not permanently close the source. Final teardown cancels SMB and stops the engine. No full-file download is required.

Engine options request 128 MiB session retention and four forward segments. Mux buffers, decoded frames, engine working storage, and AVPlayer allocations are additional: this is not a process-memory or total-disk cap. Autoplay is disabled during preparation so the host controls presentation and saved-position restoration.

## Dependencies and FFmpeg isolation

Vendored AetherEngine revision `814fef14d394c13c378869dc5c13963af8be9a0d` uses LGPL v3 with upstream Apple Store/DRM exception. The local package retains sources and compiler compatibility annotations; optional traits are off. Its pinned dependencies include FFmpegBuild 3.9.0 and LibDovi 2.1.0. Preserve bundled notices and exact package resolutions.

AetherEngine's dynamic FFmpeg and BoraMin's legacy static FFmpeg must not interpose each other's C symbols. Legacy MediaBridge and FFmpeg live inside private BoraMinMedia.framework, exporting only `media_*`. Verify after building:

```sh
python3 tools/verify_media_linkage.py /absolute/path/to/BoraMin.app
```

The software-control design follows [AetherPlayer's architecture](https://github.com/superuser404notfound/AetherPlayer/tree/f6cf1c6bab8bf969e4dc576df2914fb589281497), using public surface/playback APIs. No AetherPlayer UI source was copied. Private AVKit view-name inspection and chrome suppression are not used. New custom integrations require the maintainer's approval; existing software controls and source-track menus were approved.

## Limitations

Recognized containers do not guarantee codec/profile compatibility. Software controls and the separate VP9 video layer do not inherit native thumbnail scrubbing, every gesture, PiP, or AirPlay. App-rendered subtitles do not accompany external playback. Bitmap subtitle placement can need further work for unusual cropped-video canvases.

Native-to-software transitions are observed by the hosts, but recovery from a real failing native file has not been comprehensively device-tested. A failure that the engine cannot recover still reports an error. Long playback, memory/disk retention, blocked SMB cancellation, slow/interrupted networks, and exact HDR/A/V output need broader verification. Live streams, disc navigation, and arbitrary URLs are outside the SMB-file interface.

## Tests and recorded evidence

October 27: HEVC/AAC fixture HEVC/AAC MKV still fails the native route on physical Apple TV (tvOS 27): HDR master rejection -11868/-17223, then media-playlist rejection -11829/-12848 after init/segment loading. Its AAC configuration matches the previously investigated Program Config Element audio in [the native audio report](../Tests/Native-audio-compatibility.md); audio configuration is a suspect, not a newly isolated cause. Forcing AetherEngine's alternate path produces continuously advancing rendered frames; logs select `HardwareVideoDecoder (VT HEVC)`, and the user confirms moving video and sound. iOS has the same user-reported opening failure; the shared fix builds for iOS, but device playback remains unverified. Logs are under ignored `build/PlaybackFailures/`.

The same day's surround fixture MP4 failure on Mac is not reproduced with the installed 0.3 build: both the direct SMB resource-loader probe (including saved-position seeking) and the user's app retest play. An older 0.1 Debug copy was found running during diagnosis; this does not prove which build produced the original error. No MP4 playback change was needed.

Use [Tests/README.md](../Tests/README.md) for current probe commands. `--aether-diagnostics` enables redacted engine diagnostics; use it with the existing stream and decoded-frame checks. An advancing audio clock alone is insufficient evidence of working video.

The isolated Mac software probe uses MPEG-4 Part 2 AVI with two MP3 audio tracks. October 25 checks passed actual sample-buffer rendering, audio switching, pause, forward/backward seeks, saved-position resume, consecutive windows, and completion cleanup. All three schemes built. This does not establish complete real-device software fallback coverage.

### Initial native MKV measurements (historical)

These measurements precede automatic routing and the unified track menu. Their file-specific failures are historical observations, not a current compatibility matrix.


- Release builds pass for tvOS, iOS and macOS with Xcode 26.3.
- `tools/verify_media_linkage.py` passes for all three built applications: legacy exports are restricted, `media_open_io` binds to BoraMinMedia, and engine FFmpeg calls bind to AetherLibavcodec/AetherLibavformat. Both Apple TV and Mac deep signature checks pass.
- Existing Mac native MP4 video/track menus, forward/backward seeks, pause, teardown, consecutive windows and legacy MKV playback regression pass (`build/Aether-legacy-regression.log`). This CLI check exercises the unchanged legacy route, not AetherEngine playback.
- Apple TV tvOS 27.0: surround fixture native playback and pause/repeated/distant seek control test pass. The HDR master fails -11868, and AetherEngine automatically switches to the media playlist. Native video is 3840×1600 HEVC; TrueHD audio is decoded/re-encoded by the engine to native E-AC-3 (48 kHz, six channels). User confirmed moving video and sound. Native hardware/software decoder choice remains unknown.
- Decoded-frame checks pass at 6,000, 20, 9,000, 5 and 125 seconds, with fresh continued frames after every jump. Seek-to-first-frame latencies: 7.02, 2.51, 7.58, 1.30 and 7.37 seconds respectively. The host's startup frame check took 0.67 seconds after engine preparation; this excludes connection/probe/remux setup and is not total time to playback. Near-end seek and AVPlayer's end notification pass; engine returns to idle and its loopback server shuts down.
- Short-run peak sampled resident memory: 264.1 MiB; SMB cache at most 128 MiB. Across all these seeks, fetched roughly 706 MB of a 42.5 GB source. Pause allowed approximately 34 MB of additional prefetch over two seconds. Engine disk retention and long-run growth were not measured.
- Different-file lifecycle test: surround fixture opens and dismisses, but HEVC/AAC fixture HEVC/AAC MKV then fails AVFoundation -11829 with CoreMedia -12848 after init/segment loading. No decoded frame; the same file also failed the earlier GMPlayer native-HLS test on Mac. This remains a file/native-media compatibility limitation, not proof of a crash or a failed teardown. The adapter now rejects an already-failed item even when engine.load returns without throwing.
- Raw logs are ignored `build/Aether-tv-bladerunner.log` and `build/Aether-tv-lifecycle.log`.
- Reopen control: surround fixture opens, renders a fresh native frame and dismisses three times in the same process. No lifecycle crash observed (`build/Aether-tv-reopen.log`).
- Saved-position restoration: isolated test preferences restored 75 seconds and produced a matching native frame at PTS 74.992 (`build/Aether-tv-resume.log`). Real playback history/iCloud records were not changed.
- No iPhone device was used.


Later audio preference/selection tests selected native AC-3 instead of TrueHD conversion, and Apple TV users confirmed both source tracks and switching. Subsequent unified track controls cover iOS and Mac too. Current subtitle validation is recorded in the subtitle guides.
