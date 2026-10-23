# Large MP4 streaming investigation — 2026-10-23

## File and symptoms

The surround fixture MP4 is 41,709,653,628 bytes, duration 9,759.125 seconds, with HEVC Main 10/Dolby Vision 8.1 video, TrueHD/Atmos, AC-3, and a chapter track. The movie index (`moov`) is 65,382,721 bytes at the end of the file. The TrueHD track alone accounts for 57,759,291 index bytes, including 11.7 million sample-size entries.

The Apple TV can seek/show thumbnails but stays waiting for playback for over a minute. Selecting AC-3 succeeds (confirmed in device logs), but does not resolve the stall. Other user-tested files play normally.

## Controlled checks

On macOS 15.7.4, using AVPlayer and explicitly selecting AC-3:

- Mounted-file playback advances for 20 seconds without an error. A separate test seeks to 168 seconds and advances to 187 seconds without waiting. These initial checks measure clock/status only.
- Through BoraMin's existing SMB/HTTP transport, the same file fails native track/media-selection loading with AVFoundation -11800 and underlying -12876.
- Three HTTP ranges match the mounted source byte for byte: the initial 1 MiB, a 1 MiB media range near 173 MB, and the complete 65,382,721-byte movie index. The full index transfer took 7.65 seconds in this run. This verifies these ranges, not every byte of the 41.7 GB file.
- An independent loopback HTTP range server reading the mounted file reproduces the same AVPlayer failure. That isolates a failure beyond BoraMin's SMB/cache implementation.
- A diagnostic-only HTTP view changes just the TrueHD `trak` atom type to an equal-size `free` atom. All offsets, file length, media samples, video metadata and the original file remain unchanged. With that view, AVPlayer loads, selects AC-3, advances normally and produces decoded video frames on repeated samples; buffering reaches approximately 148 seconds ahead during a 20-second run.
- The filtered view also resumes decoded video after forward and backward seeks (targets 6,000 and 168 seconds). Seek completion callbacks take approximately 0.54 and 0.26 seconds; these are not seek-to-first-frame timings. Default AVPlayer seek tolerances allow landing several seconds past the requested position.
- Trying Apple's standard `AVPlayerItemTrack.isEnabled` approach cannot get past the original HTTP asset's loading failure: item status becomes failed before usable tracks are exposed.

## Interpretation and limits

The TrueHD track/index triggers an AVFoundation HTTP compatibility problem in this file. The tests do not distinguish unsupported TrueHD parsing from its unusually large sample tables or another property of that track. High video bitrate or a 128 MiB cache limit alone does not explain the controlled results.

The successful diagnostic HTTP view has been tested on the Mac, not on Apple TV. It does not yet establish an Apple TV fix, long-run reliability, audio/video synchronization, HDR fidelity or general MP4 filtering correctness. No production container filter has been added. Original movies are untouched.

## Proposed next step

Subject to the user's required approval for custom integration, add a bounded MP4 compatibility filter in the existing HTTP transport to omit unsupported audio tracks from the index while preserving byte offsets and media payloads. Validate MP4 atom bounds, support ordinary/extended-size atoms, skip unsupported layouts safely, and preserve supported audio, subtitles, chapters and video metadata. Verify startup, actual video output, forward/backward seeks, saved-position resume and repeated playback on Apple TV before claiming the problem fixed.

Apple's public track presentation API is documented at [AVPlayerItemTrack.isEnabled](https://developer.apple.com/documentation/avfoundation/avplayeritemtrack/isenabled). It acts on loaded item tracks; it is not an API for removing an unsupported track from a container before loading.

Diagnostic scripts/logs are in the ignored `build/StreamingStall/` directory.

## Follow-up: standard APIs, after the user declined filtering

The user requested continued investigation of standard APIs only; no container filter is authorized.

- Explicit `AVURLAssetPreferPreciseDurationAndTimingKey=true` plus the public MIME override does not fix the independent HTTP reproduction.
- An opt-in Apple TV diagnostic disables audio item tracks whose formats lack an AudioToolbox decoder, selects AC-3, and calls `playImmediately(atRate: 1)`. It produces an initial 3840×1600 frame at about 2.94 seconds, but the user confirms continued freezing/spinning. This is not a fix. Normal playback defaults remain unchanged. The unsuccessful opt-in diagnostic was removed from source after testing; the installed diagnostic build has not yet been replaced.
- A standalone `AVAssetResourceLoaderDelegate` diagnostic serves the original MP4 bytes with its original tracks and index. With `isEntireLengthAvailableOnDemand=true`, mounted-file and SMB-backed tests produce decoded frames and a playing clock for 20 seconds. The SMB test fetches bounded ranges through the existing proxy; it does not download the whole movie.
- The SMB-backed on-demand loader also passes exact seeks to 6,000 and 168 seconds and produces decoded frames afterward. After the backward seek, the first two-second sample had no new frame; subsequent samples did. Long-run synchronization and stalled-network recovery are still unverified.
- Setting the same loader's `isEntireLengthAvailableOnDemand=false` reproduces the native loading failure. Thus, the loading mode matters, not only the HTTP implementation or selection of a codec.
- This public API is not a stock SMB player: production use would require a byte-loading delegate and careful handling of availability, cancellation and errors. The property describes immediately available data, typically cached or file-backed. Its suitability for remotely available SMB data must not be assumed merely because this fast-network test succeeds. Slow/interrupted-network behavior and Apple TV output remain unverified.

See Apple's [on-demand content availability documentation](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingcontentinformationrequest/isentirelengthavailableondemand) and [resource-loading content information](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingcontentinformationrequest).

## Approved opt-in Apple TV resource-loader test

The user approved adapting the existing resource-loader delegate for an opt-in test, without remuxing/filtering/custom decoding. `StreamingFileLoader` is compiled in the shared loader source; `NativePlayerController` uses it only with `--test-native-file-loader` and native MP4/M4V/MOV streaming. Normal launches retain HTTP. Mac playback routing is unchanged. The original index, TrueHD track, AC-3 track and video samples are served unchanged through the 128 MiB SMB cache. New loading tasks are cancelled at seeks/dismissal; individual response chunks are at most 256 KiB.

Apple TV reported **tvOS 27.0** in this test (app deployment target 26.6). The native frame probe confirmed 3840×1600 output with timestamps near the player clock:

| Check | Observed result |
| --- | --- |
| Startup, measured after controller setup | First confirmed frame in 1.48 s |
| Pause/resume | Clock held; 256 KiB additional fetched while paused |
| Seek to 6,000 s | Confirmed frame in 2.79 s; continued frames after 2 s |
| Seek to 20 s | Confirmed frame in 1.47 s; continued frames after 2 s |
| Seek to 9,000 s | Confirmed frame in 1.21 s; continued frames after 2 s |
| Seek to 5 s | Confirmed frame in 0.86 s; continued frames after 2 s |
| Seek to 125 s | Confirmed frame in 0.90 s; continued frames after 2 s |
| Seek near end | Confirmed frame at 9,756.125 s |
| Bounded source cache | At most 134,217,728 bytes (128 MiB) |
| Last measured process resident memory | Approximately 210 MiB |
| Total SMB bytes fetched during controls test | 216,714,876 bytes, about 207 MiB, from a 41.7 GB source |

The controls probe reports PASS. The near-end frame is verified, but automatic dismissal still requires log/user confirmation. Video timing is measured from actual pixel buffers; this test does not measure audio/video synchronization or confirm HDR rendering. Audio requires the user's listening confirmation. All three platform Release builds pass. Raw output: `build/StreamingStall/tv-loader-controls.log`.

The unsuccessful `--test-native-immediate` diagnostic was removed from source and replaced on device by this build. After the automated test, the movie was relaunched with the opt-in loader and no automatic seeking for visual/listening confirmation. The `--no-playback-history` flag avoids changing saved progress during these tests.

### Follow-up viewing and remaining caveats

The first console-attached viewing launch terminated with signal 13; no new BoraMin crash report was present in the device's crash-log listing afterward. The cause has not been established, so this must not be described as a resolved playback crash or attributed conclusively to console redirection.

A subsequent launch without console attachment explicitly enabled the file loader and selected AC-3. The user then confirmed “it's working now.” Device logs show continued playing at 13.00 and 28.25 seconds and at 91.75 seconds after the user's rapid manual forward seeks (targets 42–82 seconds). The last measured cache occupancy was 134,139,516 bytes, process resident memory 180,453,376 bytes, and thermal state normal. These support short-run playback and remote seeking; they do not establish long-run stability or precise sound/video synchronization.

The controls-test startup timing excludes initial SMB preparation of the large index. The viewing launch logged stream readiness at 12:11:28, item readiness at 12:11:29, and a decoding-label display (requires playing state) at 12:11:32. Thus the 1.48-second frame measurement must not be advertised as total tap-to-playing latency.

No production default was switched. A normal Home Screen relaunch lacks the opt-in flag and continues to use the original HTTP path. The current explicitly launched test process uses the loader for eligible native MP4/M4V/MOV files. Further rollout needs validation of availability semantics under slow/interrupted SMB, repeated opening/resume, longer playback, and the signal-13 observation.

## Default integration approved

The user subsequently requested implementation. Native SMB MP4/M4V/MOV playback now uses `StreamingFileLoader` by default on iOS, tvOS and macOS, with the same native AVPlayer/AVKit controls and supported-audio selection. No launch flag is needed. Local/native non-streaming playback and other formats keep their existing routes. MKV/WebM are unchanged. The earlier opt-in statements above describe the investigation history, not the current default.

The 128 MiB source cache remains bounded; the file loader returns chunks no larger than 256 KiB, propagates source read failures through AVFoundation's loading-error API, and cancels loading tasks when requests or players are dismissed. The initial MP4 index still needs to be fetched, so large indexes can delay startup. Network outages may produce a playback error requiring reopening the video; seamless outage recovery and long-run stability are not claimed. The previous console-attached signal-13 observation remains unexplained.

Default-integration verification: signed Release builds succeed for iOS, tvOS and macOS. The Mac integration probe passes native MP4 video/audio/subtitle groups, forward/backward seeks, pause, teardown, consecutive players, and the unchanged MKV path. On Apple TV, the surround fixture test without `--test-native-file-loader` confirms native output at startup and after repeated seeks; measured seek-to-frame latency is approximately 0.8–1.5 seconds in this run, with the source cache staying within 128 MiB. Logs: `build/StreamingStall/default-tv-controls.log`, `default-mac-probe.log`, and `default-{tvos,ios,macos}.log`. Initial frame timing excludes SMB metadata preparation. No iPhone device testing was performed.
