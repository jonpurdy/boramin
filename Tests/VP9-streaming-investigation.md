# iPhone VP9 streaming investigation — 2026-10-22

## Findings

Tested the original VP9 HDR fixture 4K/59.94 fps, Profile 2, 10-bit HDR MKV on test device. VideoToolbox confirmed hardware decoding. A separate 24-second local test using copied compressed packets played without late drops at diagnostic checkpoints, so disabling hardware decoding is not supported by the evidence.

The SMB audio and video readers share an LRU cache. Their different read positions can evict data the other reader still needs. Controlled runs started at zero with playback-history writes disabled:

| Cache / read block | Observed playback | Previously fetched bytes fetched again | Latest decoded / queued / late counts |
| --- | --- | --- | --- |
| 32 MiB / 256 KiB | Audio 32.75s; video stuck at 9.96s | 74.25 MiB | 1,500 / 346 / 1,152 |
| 128 MiB / 256 KiB | Audio 95.25s; video 94.995s; no sustained freeze | 0 | 5,700 / 4,102 / 1,596 |
| 128 MiB / 1 MiB | Audio 70.25s; video 70.370s; no sustained freeze | 0 | 4,200 / 3,332 / 866 |

Counts are the latest periodic checkpoints, not necessarily the final timestamp sample. Late counts measure decoded frames discarded before enqueue because they missed the audio clock, not frames measured on the display. Thermal state stayed nominal and the renderer reported rendering. These are individual runs of one clip, not proof of smooth playback across the library.

The larger cache eliminated duplicate fetches even after total fetched bytes exceeded its capacity. It prevented the sustained freeze in these runs, but late-frame bursts remained. Larger reads alone also did not eliminate them.

Source inspection found a second issue: `SMBRemoteFile.read` holds its single cache lock throughout the blocking network fetch. An audio cache miss therefore blocks even a video cache hit. This is a plausible contributor to remaining late frames; its effect has not yet been measured in isolation.

## Original proposal

1. Use a 128 MiB compressed-file cache for iOS VP9 streaming, adding at most 96 MiB of cached payload compared with today. Retain current defaults on tvOS and other playback paths.
2. Separate the short-lived cache lock from the serialized network-fetch lock. On a miss, release the cache lock, acquire the fetch lock, recheck the cache, fetch, then insert under the cache lock. Cached reads can proceed while a network request is pending; network misses remain serialized.
3. Keep hardware decoding and native player controls. Retest sustained playback, seeking and repeated playback on test device, and verify tvOS remains unaffected.

The memory increase applies to compressed cached data; total player memory also includes decoder surfaces and audio buffers. Further tuning depends on measured results after these changes.

## Diagnostic changes and evidence

The investigation added opt-in test instrumentation: cache hits/misses/refetched bytes and launch flags `--test-stream-cache-mib` (32, 64, 128, 256) and `--test-stream-block-kib` (256, 512, 1024). The installed diagnostic build passed the iOS Release build; normal launch was restored after testing.

Following the investigation, the user approved a 128 MiB cache for **all streaming formats on both iOS and tvOS**. That shared default is now applied. The 256 KiB block size and existing lock behavior remain unchanged; the separate-lock proposal has not been applied.

Local console logs:

- `/tmp/boramin-test device-cache32.log`
- `/tmp/boramin-test device-cache128.log`
- `/tmp/boramin-test device-cache128-block1024.log`
- `/tmp/boramin-vp9-cache-experiment-build.log`

Attached-console timeouts ended observation; they do not indicate an app crash.
