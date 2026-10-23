# Converted HEVC/AAC MP4: native AAC compatibility — 2026-10-22

The user reported silent audio in `fallback.mp4` and requested that the file remain unchanged after diagnosis. No production playback code or source media was modified. Testing used only Apple TV; test device was not accessed.

The current MP4 contains HEVC Main 10 HDR video, one Korean AAC-LC audio stream (48kHz, six channels), and an embedded English mov_text subtitle. FFmpeg reports the audio channel layout as unspecified/unknown. Its 26-byte AudioSpecificConfig uses channelConfiguration=0 and a Program Config Element, rather than a standard implicit channel layout. The current MKV has identical AAC extradata, so stream-copying that audio into MP4 retains the issue.

A three-second FFmpeg decode from 60s confirmed non-silent audio: mean -27.6dB, peak -8.7dB. This is not a missing soundtrack. The nonstandard configuration is a compatibility suspect; the tests isolate native recognition failure, not the exact offending bit in that configuration.

An isolated Apple TV app configured a standard playback/moviePlayback AVAudioSession and tested short local diagnostic samples. On Apple TV OS 27.0:

| Sample | AVFoundation audio tracks | Native PCM decode | AVPlayer |
| --- | ---: | --- | --- |
| Original movie clip, video/audio stream-copied | 0 | No track to decode | Video timeline advances; unmuted, volume 1; no item error |
| Original audio stream-copied to M4A | 0 | No track to decode | Asset not playable |
| Sample re-encoded as standard 5.1 AAC | 1 | 4,614,048 non-silent PCM bytes | Ready, clock advances |
| Sample re-encoded as stereo AAC | 1 | 1,538,016 non-silent PCM bytes | Ready, clock advances |
| Same movie video copied with stereo AAC audio | 1 | 1,538,016 non-silent PCM bytes | Ready, clock advances |

The six-channel control explicitly assigns a 5.1 layout for compatibility testing. It does not establish the original nonstandard channel-to-speaker mapping. No claim is made that relabeling the original six channels as 5.1 preserves their intended positions. Stereo AAC was offered as a separate corrected copy, with video and subtitles copied unchanged; the user declined. The original MP4 and MKV remain untouched.

Conclusion: this soundtrack is not recognized as an audio track by native AVFoundation on the tested Apple TV. A media-selection UI change cannot select a track the framework does not expose. Re-encoding only the audio to a conventional AAC configuration is a demonstrated compatibility remedy; no custom decoding fallback or remux route was added.

Evidence: `/tmp/boramin-native-audio-probe-run.log`, `/tmp/boramin-mp4-audio-check.log`; source `Tests/NativeAudioProbe.swift`. Diagnostic clips/project are under ignored `build/NativeAudioProbe/`. Attached-console timeout after COMPLETE is an observation timeout, not an app crash. The diagnostic app was removed and normal BoraMin was restored on Apple TV.
