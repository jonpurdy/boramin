# Native VP9 playback investigation — 2026-10-22

## Conclusion

The separate VideoToolbox/display-layer pipeline is **not inherently necessary for VP9**. On the current physical test device and Apple TV, AVPlayer directly played the VP9 HDR fixture VP9 stream after lossless remuxing to MP4. Both devices reported OS **27.0** during this investigation. This does not establish support on tvOS 26.6 or all devices/profiles.

MKV and WebM remained unplayable through AVPlayer. BoraMin's current separate layer is part of its MKV/WebM demux/decode integration, rather than a demonstrated fundamental limitation of AVPlayer's VP9 decoding.

No production player code, preferences, credentials, bookmarks or playback policy changed. Tests used a separately signed diagnostic app, subsequently removed from both devices.

## Method

Before asset creation, the probe called the public `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)` API. It then used an ordinary AVPlayerViewController and AVPlayerItem, with no custom video layer or decoder. AVPlayerItemVideoOutput sampled decoded pixels at approximately 100 ms intervals to distinguish actual video from audio-only clock advancement.

The original local VP9 HDR fixture MKV contains 3840×2160, approximately 59.94 fps, Profile 2, 10-bit HDR VP9 with AAC audio. FFmpeg copied compressed packets into four-second container variants. SHA-256 hashes of all 240 video packets matched the original MKV. MP4 metadata retained 10-bit BT.2020/PQ color tags. A generated H.264/AAC MP4 served as a positive control. The existing source MP4 in the lab is AV1, so it was not used as the VP9 input.

## Results on both devices

| Input | Native result |
| --- | --- |
| H.264/AAC MP4 control | Ready; approximately 39–40 sampled video images; playback reached 4s |
| VP9/AAC MKV | Failed to open, AVFoundation -11828 / underlying -12847 |
| VP9-only WebM | Failed to open, same errors |
| VP9/AAC MP4 with faststart | Ready; 40 sampled 3840×2160 images; playback reached 4.003s |
| VP9-only MP4 | Ready; 39–40 sampled 3840×2160 images; playback reached 4.003s |
| Fragmented VP9/AAC MP4 | Ready; 39 sampled 3840×2160 images; playback reached 4.003s |

All three VP9 MP4 variants reported `AVAsset.isPlayable == false` while their video tracks reported `isDecodable == true`. Despite that, AVPlayerItem became ready and returned actual decoded video frames. Do not use isPlayable as the sole rejection criterion in any future experimental native VP9 path. Conversely, item readiness or audio-clock advancement alone does not prove video rendering.

A second test used a 24-second VP9/AAC MP4 remux. After approximately 18 wall-clock seconds:

- Apple TV: clock 17.705s, 165 sampled 3840×2160 images, controller ready for display, no item error. Pause held the clock unchanged. Exact seek to 12s completed; playback advanced to 14.718s with 26 further sampled images and display readiness retained.
- test device: clock 17.806s, 167 sampled 3840×2160 images, controller ready for display, no item error. Pause held the clock unchanged. Exact seek to 12s completed; playback advanced to 14.962s with 28 further sampled images and display readiness retained.

Sample counts measure the diagnostic polling rate, **not** delivered frame rate or dropped frames. Hardware capability returned true, but AVPlayer does not expose its internal decoder's hardware-use property; the probe does not claim confirmed hardware decoding. Tests did not measure HDR output correctness, audible audio quality, native pinch interaction, long-session stability, or network playback. Fragmented MP4 was tested as a local file, not HLS.

## Recommended next step

Retain the current working pipeline while adding an experimental AVPlayer path for compatible VP9 MP4. Confirm video display readiness, seeking, audio and HDR on target OS versions, and retain a fallback for failures. Decoder UI for this native path must say system decoding/HW-SW unknown.

For MKV/WebM, add a streaming remux stage that exposes seekable MP4/fMP4 to AVPlayer through the existing loopback HTTP transport. Preserve compressed video; compatible audio can also be copied. Other audio formats need separate compatibility checks. This is new container/transport integration, not a decoder toggle. Seeking, startup latency, bounded buffering and byte-range handling need explicit design and testing so playback does not require a whole-file download. The bundled FFmpeg configuration currently has demuxers but no MP4 muxer, so its configuration and C bridge would need expansion if used for remuxing.

Native AVPlayerViewController supplies its standard video gestures for native video tracks. No production gesture or rendering change is part of this investigation.

## Reproduction

Source: `Tests/NativeVP9Probe.swift`, intentionally outside all production source globs. Generate fixtures and an isolated project with:

```sh
python3 tools/create_native_vp9_probe.py --make-fixtures
```

This uses the adjacent lab's original MKV and host FFmpeg, placing generated media/project under ignored `build/NativeVP9Probe/`. Build scheme NativeVP9Probe for generic iOS or tvOS with separate derived-data directories. The diagnostic bundle ID is `com.example.BoraMin.NativeVP9Probe`. Normal launch tests six short variants; `--long-only` tests longer playback, pause and seek. Build and run the probe on physical devices; simulator results cannot establish device hardware behavior.

Console evidence: `/tmp/boramin-native-vp9-{ios,tv}-run.log` and `/tmp/boramin-native-vp9-{ios,tv}-long.log`. Build logs: `/tmp/boramin-native-vp9-{ios,tv}-build.log`. Attached-console timeouts end observation and do not indicate an app crash.

## Sources

- [Apple: supplemental decoder registration](https://developer.apple.com/documentation/videotoolbox/vtregistersupplementalvideodecoderifavailable(_:)) — public API registers a decoder if available; it does not promise every container/profile works.
- [Apple: AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput) — public decoded-image output used by the probe.
- [Original macOS VP9 AVPlayer demonstration](https://github.com/rinsuki/HWAcceleratedVP9Player) — source-author demonstration of registration plus VP9 MP4 playback on macOS; motivation for this device test, not evidence of iOS/tvOS compatibility by itself.

## Follow-up

The opt-in SMB/fMP4/HLS prototype and its device comparison are documented in [Streaming-remux-investigation.md](Streaming-remux-investigation.md). The unchanged-production-code statements above describe the original isolated MP4 investigation; the follow-up adds a launch-flag-only adapter while retaining the default path.
