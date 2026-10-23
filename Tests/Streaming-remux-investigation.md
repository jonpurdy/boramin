# Opt-in native VP9 streaming remux — 2026-10-22

## Decision

Keep the existing production default. The prototype demonstrates SMB → on-demand fMP4 → native AVPlayer video playback without transcoding or processing the entire source first. It is promising, but currently **not comparable in seeking efficiency** to the production pipeline. It also depends on VP9 HLS behavior demonstrated on OS 27.0 rather than an Apple guarantee for the original deployment targets.

The subsequent [GMPlayer source review](#gmplayer-source-review--2026-10-22) identifies concrete follow-up experiments, not new device results: correct HDR master declarations, test native HLS buffer defaults, and expose separate audio/WebVTT renditions. GMPlayer excludes VP9 from its codec policy, so it does not independently establish VP9 compatibility.

Nothing enables it in normal launches. `--experimental-vp9-remux` opts in for VP9 SMB streams only. No settings toggle, preference migration, private API, custom gesture, custom video renderer, or default-policy change was added. Other formats continue along their existing paths.

## Compatibility gate

Read `Native-VP9-investigation.md` first: the earlier local MP4 test alone did not prove HLS compatibility. A separately signed diagnostic app now serves packet-copy fMP4 fixtures through a loopback HTTP server using Network.framework and AVPlayerViewController.

Both physical devices reported **27.0**: iPhone **test device** and the paired Apple TV. SDK: Xcode 26.3 / SDK 26.2. This investigation does not establish compatibility on iOS 26.x / tvOS 26.6, other devices, or other VP9 profiles.

| Transport fixture | Both devices |
| --- | --- |
| H.264/AAC HLS master playlist | Actual 640×360 pixels; ready |
| VP9/AAC HLS master declaring `vp09.02.51.10,mp4a.40.2` | Failed, CoreMedia -12927 |
| VP9/AAC direct HLS media playlist | Actual 3840×2160 pixels; ready; clock advanced |
| HEVC/AAC master control with CODECS omitted by FFmpeg | Failed, -12927; not investigated further |

The failed HDR master fixtures omitted `FRAME-RATE` and `VIDEO-RANGE`; the VP9 source requires a PQ declaration. GMPlayer documents similar HDR declaration errors causing -12927. **The failure therefore does not isolate VP9 codec compatibility. Corrected master playlists have not yet been retested.** See the source review below for evidence and the proposed follow-up.

The prototype deliberately uses the successful **direct media playlist**. The failed master variant is an observed fixture result, not proof that every possible VP9 master is impossible. Multiple audio/subtitle renditions typically need a master playlist; this prototype does **not** solve track selection.

AVPlayer decoder selection remains **System Decoding (HW/SW unknown)**. The production VP9 path explicitly requires and verifies a hardware VideoToolbox session; the native path does not expose equivalent confirmation. Its decoding label and debug panel now respect this distinction.

## Integration and bounds

- Existing SMB random-access AVIO and its shared **128 MiB** LRU are reused.
- Existing Matroska cue discovery supplies the complete keyframe index with its existing 4 MiB discovery budget. Missing/incomplete indexes fail the opt-in path rather than scanning the whole video.
- A VOD media playlist describes the entire timeline. Segment requests seek directly to the corresponding source keyframe and copy compressed VP9 and AAC packets through FFmpeg's MP4 muxer. No pixel decoder/encoder runs in FFmpeg.
- New FFmpeg configuration enables only the MP4 muxer; network protocols and software video decoders remain disabled.
- `frag_discont` retains original absolute timestamps when each fragment is independently muxed. Fragment sequence numbers are stable. Initialization bytes must match across requests.
- Independent fragment intervals must be positive and at most 30 seconds. At most 100,000 cue entries are accepted. Video starts near zero; currently restricted to 4:2:0 VP9 at 8/10/12-bit and AAC or no audio. Other combinations fail the experimental path; their existing default playback is unaffected.
- The muxer staging budget is **24 MiB compressed payload / 65,536 packets** per fragment. Output is capped at **32 MiB**, and AVIO reads at **64 MiB per fragment**. This bounds FFmpeg's internal staging as well as the final output buffer. Oversized fragments fail explicitly.
- Two generated fragments are retained: at most **64 MiB**, plus initialization under 4 MiB. Four simultaneous experimental HTTP connections maximum; transient response/working buffers are additional bounded allocations. AVPlayer's internal buffers/decoder allocations are system-managed and not covered by the app's LRU limit.
- The adapter writes no movie/fragments to disk (zero app-managed disk buffer); AVFoundation may use system-managed caches outside its direct control. Diagnostic fixture generation on the development Mac is separate from device playback.
- Network reads can fail without poisoning subsequent attempts: the remux demuxer is closed/reopened after errors; HTTP returns 503 so native HLS loading can retry. Aborted requests from normal seeks may log broken pipes.

This is custom container/transport integration using public FFmpeg and Apple APIs, explained before implementation. AVPlayerViewController owns native controls, seeking, and gestures. There is no added pinch recognizer. Gesture interaction itself still needs manual verification.

## Payload/timestamp verification

`python3 tools/test_streaming_remux.py` generates distant fragments before intervening ones, then all fragments. The tests verify identical initialization, oversized-fragment rejection and complete source packet hashes/timestamps:

- All **9,506 VP9** packet hashes identical; **zero** PTS change.
- All **6,832 AAC** packet hashes identical; maximum PTS difference **11 μs** (audio timescale rounding).
- These are mux correctness checks, not proof of audible synchronization or HDR output correctness.

## Normal-SMB comparison

Original VP9 HDR fixture MKV: 559,556,554 bytes, 158.639 seconds, 3840×2160 59.94 fps, VP9 Profile 2 10-bit BT.2020/PQ + AAC. Tests use the saved server connection, with user playback history disabled. Test order: startup, pause 2s, seek 125 → 20 → 90 → 5 → 125 seconds, check continued video after each, then seek near the end and wait for native completion.

| Metric | test device native remux | test device current | Apple TV native remux | Apple TV current |
| --- | ---: | ---: | ---: | ---: |
| Controller creation → first confirmed video | 0.48s | ≤2.46s | 0.64s | ≤4.02s |
| Seek 125s | 4.72s | ≤1.75s | 3.09s | ≤1.04s |
| Seek 20s | 3.81s | ≤2.05s | 1.87s | ≤1.03s |
| Seek 90s | 3.85s | ≤1.75s | 1.93s | ≤1.08s |
| Seek 5s | 1.78s | ≤0.20s | 0.89s | ≤0.20s |
| Repeat seek 125s | 2.43s | ≤0.97s | 1.51s | ≤0.52s |
| Total SMB transfer through completion | 236.2 MB | 206.6 MB | 237.5 MB | 203.7 MB |
| Largest sampled process resident memory | 406 MiB | 279 MiB | 241 MiB | 195 MiB |
| SMB cache upper bound | 128 MiB | 128 MiB | 128 MiB | 128 MiB |

Startup measurements exclude SMB connection/directory lookup and source probing before controller creation. Seek timing starts before the native seek call and ends at confirmed video. Native seeks are exact; the current path snaps to a nearby keyframe, so requested visual positions differ slightly. Current-path measurements pause momentarily to read the public renderer's displayed buffer and are conservative upper bounds, not exactly identical instrumentation. Tests were sequential on the same source/network, without controlled network QoS or OS cache flushing; treat these as exploratory measurements, not benchmark claims. Resident memory is sampled process RSS using public Mach task info, not a measured peak or total device/GPU footprint.

Native results require AVPlayerItemVideoOutput pixels with presentation timestamps near the current clock, and AVPlayerViewController readiness. Seek frames were within ~17ms of the media clock; subsequent changed timestamps/pixels were also sampled. Sampling at 50ms intervals does not measure actual delivered 60fps, drop rate, audible audio delay, or lip sync. Production output was confirmed via the public paused-renderer pixel buffer. Native labels do not claim hardware decoding.

Both native runs paused without clock drift, produced video after all five seeks, advanced afterward, and completed back to the browser. Native HLS may finish an in-flight prefetch during pause. The complete source is not fetched first: native playback began after about 4.3–4.6 MB transferred, versus a 559.6 MB source. Later requests jumped directly from early fragments to source regions near 125s.

## Connectivity tests

Diagnostic hooks affect only runs with `--exercise-remux-faults`; no real network configuration is changed. Slow-link simulation adds 150ms to each uncached 256KiB SMB read. A four-second outage makes uncached SMB reads fail, then recover. These test data delivery and error recovery, not SMB socket/session reconnection after an actual server restart.

- Native remux: slow seek to 90s produced real frames after **40.34s (test device)** / **39.98s (TV)**. The player must fetch substantial preroll at below-source-rate throughput; it cannot conceal bandwidth below the source's requirements.
- After a four-second injected outage while seeking to 125s, HLS retried and returned real video after **8.63s (test device)** / **7.85s (TV)**. Neither native run failed the player item.

The current test device pipeline reached video after the slow seek in **10.85s**, then failed its video packet reader with FFmpeg -5 on the injected outage and dismissed playback. The first TV baseline-fault attempt failed before injection with an unrelated SMB/AVFoundation error (-11800 / POSIX 1), so it is not a valid fault comparison. A second TV attempt failed at the same startup stage before injection. Consequently there is **no valid TV production fault comparison**; both failed runs are retained, rather than presented as outage results.

## Saved positions and player lifecycle

The final lifecycle tests passed on **both** devices: open VP9 HDR fixture, restore a saved 75s position and confirm real 3840×2160 frames; dismiss; open the real HEVC movie and confirm 1920×1080 frames; dismiss; reopen VP9 HDR fixture, restore 75s and confirm frames again; dismiss. All three cycles ran in one process with no crash.

The saved position was written/read through PlaybackPositions in an isolated temporary UserDefaults suite and then removed; the same restore-seek flow is exercised without changing the user's real history or iCloud bookmarks. This does not independently test process-relaunch persistence, already covered by bookmark unit tests and previous production checks.

One earlier TV lifecycle attempt lost its SMB session and did not complete. A clean final run passed with stricter confirmation: each cycle waits for a decoded-frame notification before claiming success. Logs: `/tmp/boramin-remux-{ios,tvos}-lifecycle-final.log`. Native paused seek/restore is therefore demonstrated, but the sporadic real SMB session failure remains a risk rather than something hidden by the successful retry.

## Reproduction and evidence

Build the two existing Release app schemes with rebuilt minimal FFmpeg libraries. Launch with:

```text
--experimental-vp9-remux --exercise-remux-controls --no-playback-history
--stream-smoke-test <share> <path-to-LG-Jazz.mkv>
```

Omit `--experimental-vp9-remux` for the current-path comparison. Replace controls with `--exercise-remux-faults` for synthetic network tests. `--probe-frames-only --test-resume-position --exercise-player-lifecycle --test-second-video <path>` exercises isolated saved-position restoration and opening another file. No flags are persisted; a normal launch uses production playback.

- Isolated HLS compatibility: `/tmp/boramin-hls-{ios,tv}-run.log`.
- Normal comparison: `/tmp/boramin-remux-{ios,tvos}-{run,baseline}.log`.
- Network tests: `/tmp/boramin-remux-{ios,tvos}-{faults,baseline-faults}.log`; second TV startup failure: `/tmp/boramin-remux-tvos-baseline-faults-retry.log`.
- Payload tests: `/tmp/boramin-remux-payload-tests.log`.
- Existing regression suite: `/tmp/boramin-remux-regression.log`.
- Device build logs: `/tmp/boramin-remux-{ios,tvos}-build.log`.

The compatibility fixture project is generated by `tools/create_native_vp9_probe.py --make-fixtures`; run its separate NativeVP9Probe app with `--hls-only`. Generated fixtures and build products remain ignored under build/.

## Remaining risks

Do not switch the default based on this experiment. Main unresolved issues are exact-seek preroll/transfer overhead, higher sampled memory, VP9 master-playlist compatibility, target-OS coverage, additional files/profiles/audio formats, real server disconnect/reconnect, sustained 4K60 frame pacing, HDR appearance, audible lip sync, manual native gesture checks, and alternate audio/subtitle groups. Passing a two-device single-file prototype does not remove these limits.

The GMPlayer review adds three qualifications to these results:

- Master-playlist compatibility remains inconclusive until the missing HDR declarations are corrected and tested; the observed -12927 is not a demonstrated VP9-specific rejection.
- The seek/transfer measurements describe our current segmentation and false/3s buffer settings. Native automatic HLS buffering and different segment grouping have not been compared yet; improvement is a hypothesis, not a result.
- Separate audio and WebVTT rendition groups are a demonstrated design in GMPlayer for its supported codecs, but remain unimplemented and unverified in BoraMin’s VP9 prototype. Retain SMB support and explicit memory limits; do not adopt its whole-file batch fallback under this streaming requirement.

Sources: [Apple HLS authoring specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html), [FFmpeg fragmentation/muxer options](https://ffmpeg.org/ffmpeg-formats.html), [FFmpeg 8.0.1 MOV muxer source](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavformat/movenc.c).

Cleanup: the standalone compatibility probe was removed from both devices, and both BoraMin apps were launched normally with all experimental/test flags removed. The prototype remains in source for explicit opt-in testing only.

Diagnostic isolation correction: another Watching video opened during the first TV baseline-fault run inherited its launch flags. Its bookmark moved from the observed 642.754788917s to 125.300635874s. The no-history guard now covers saves and Watching opens globally. A narrow on-device rollback matched the file size, exact test-modified value and test save-time window before restoring the original 642.754788917s position; no preferences/credentials were exported. Evidence: `/tmp/boramin-remux-tv-bookmark-restored.log`. Both apps were returned to normal launch flags afterward.

## GMPlayer source review — 2026-10-22

Reviewed gastonmorixe/GMPlayer `main-oss` at commit `3da8bda9d557c61837fb2e4c97ed662219283043`. This was source/document inspection, not an independent run of GMPlayer's device tests. No BoraMin playback implementation or default was changed during this review.

The architecture matches the direction of this prototype: random-access source → FFmpeg packet-copy fMP4 fragments on demand → loopback HTTP HLS → native AVPlayer. Its default uses separate video, selectable audio, and WebVTT subtitle rendition playlists linked from a master. Only requested renditions are generated. This is directly relevant to the original native track-picker goal. Its source abstraction currently implements local files and HTTP, not SMB; BoraMin should retain its existing SMB adapter.

Important limits: `CFFmpeg/compat.c` excludes VP9 and AV1 from its compatible-video allow-list. Its master codec formatter handles HEVC/H.264 explicitly and otherwise returns hvc1. Thus its reported HEVC results are not evidence that VP9 master playback works unchanged. Image subtitles are excluded; text subtitle conversion does not preserve arbitrary ASS styling. Its whole-file batch fallback does not meet our no-full-download-first requirement.

The most actionable finding is its HDR-master fix. Its post-mortem associates missing FRAME-RATE and wrongly declared SDR transfer with failed HDR variant selection / -12927. Its master generator emits FRAME-RATE and the resolved VIDEO-RANGE (PQ/HLG/SDR). Our failed VP9 master fixture has neither FRAME-RATE nor VIDEO-RANGE, while the source is 59.94fps PQ. The HEVC master control also failed. Therefore **our earlier master failure is inconclusive about VP9 master compatibility**: invalid/incomplete HDR declarations are a plausible alternative cause. The direct-playlist success remains valid. Retest corrected HDR manifests before concluding that native audio/subtitle groups are blocked for VP9.

Other differences worth testing separately:

- HLS buffering: GMPlayer leaves native automatic stall waiting enabled and forward-buffer duration automatic. BoraMin currently applies false / 3s to the remux prototype as well as its existing paths. Evaluate standard HLS defaults specifically for the opt-in path; do not change the production custom path blindly.
- Segmentation: it groups keyframes toward six-second transport units and absorbs short tails, whereas our VP9 prototype uses every cue as a segment. Fewer tiny requests may help, but longer units can increase seek transfer and exceed our existing 24MiB compressed-payload budget. Compare byte-bounded grouping; do not assume six seconds improves this 4K60 clip.
- Timestamps: both retain absolute fragment positions with frag_discont. Their separate CFR decode-timestamp reconstruction addresses reordered H.264/HEVC. Preserve BoraMin's already verified VP9 PTS/DTS unless a specific defect is demonstrated; do not apply a constant-frame-rate reconstruction indiscriminately to VFR input.
- Seekable single-file fMP4: their documented experience is that AVFoundation can walk many fragments before startup on long movies. This supports continuing HLS testing rather than assuming a synthetic indexed MP4 automatically fixes arbitrary seeks.
- Resource bounds: their output buffer grows via realloc without our explicit per-fragment cap. Preserve BoraMin's source, payload, output, connection and fragment-cache limits when adapting ideas.

Recommended next experiment: correct master HDR metadata and retest existing fixtures (VP9 and HEVC), then add separate audio/WebVTT renditions to the opt-in adapter. Independently compare native HLS buffer policy and segment grouping with the current measured baseline. Keep the production default unchanged until device results justify switching.

Source references:

- [Codec selection policy](https://github.com/gastonmorixe/GMPlayer/blob/3da8bda9d557c61837fb2e4c97ed662219283043/Packages/GMPlayerKit/Sources/CFFmpeg/compat.c)
- [Master/rendition playlist generation](https://github.com/gastonmorixe/GMPlayer/blob/3da8bda9d557c61837fb2e4c97ed662219283043/Packages/GMPlayerKit/Sources/GMPlayerKit/Streaming/GMStreamSession.swift)
- [HDR master-playlist investigation](https://github.com/gastonmorixe/GMPlayer/blob/3da8bda9d557c61837fb2e4c97ed662219283043/wiki/20260601T210343-multivariant-audio-picker-hdr-solved.md)
- [Playback buffer policy](https://github.com/gastonmorixe/GMPlayer/blob/3da8bda9d557c61837fb2e4c97ed662219283043/Packages/GMPlayerKit/Sources/GMPlayerKit/Model/GMPlayerModel.swift)
- [Segment planner](https://github.com/gastonmorixe/GMPlayer/blob/3da8bda9d557c61837fb2e4c97ed662219283043/Packages/GMPlayerKit/Sources/CGMStream/gm_plan.c)
- [On-demand muxer](https://github.com/gastonmorixe/GMPlayer/blob/3da8bda9d557c61837fb2e4c97ed662219283043/Packages/GMPlayerKit/Sources/CGMStream/gm_stream.c)
