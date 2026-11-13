# Intermittent audio dropouts in the HEVC/AAC fixture MKV

Reported on Apple TV over SMB and on macOS. Video keeps moving while audio drops for several seconds. The onset varies between plays. The affected MKV is selected by the `kpop` entry in the local playback manifest. On Mac, the file uses AetherEngine's software playback route after the native item is rejected.

- The passages near **19:19** and **19:41** are quiet in the source. Independent decoding confirms audio in **19:26–19:31**, where the user heard silence in BoraMin on one attempt and heard audio in mpv.
- A Mac SMB run from **18:30 to 21:30** captured a **6.3-second** decoded PCM timestamp gap beginning at **18:34.6**. The audio renderer reported insufficient data during the gap while video continued to advance. The run captured decoded audio through **19:26–19:31**.
- Three fresh Mac SMB runs sought directly to **19:26**. One showed no tap gap. Two recorded gaps of **6.8 seconds at 19:34.3** and **7.0 seconds at 19:36.6**. The second run also showed insufficient audio renderer data with advancing video. The exact **19:26–19:31** dropout was not reproduced.

The decoded PCM tap runs before audio output and may drop buffers under load. The renderer telemetry corroborates an audio delivery problem in the runs above. The cause and exact audible duration are unresolved. Apple TV has user observations but no matching diagnostic capture.

A later report included both iPhone and Apple TV and identified the AVI episode *04x07 - Binky Barnes, Wingman; To Beat or Not to Beat*. Independent decoding found continuous stereo MP3 timestamps. An isolated Mac run through BoraMin's AetherEngine adapter reproduced four out-of-order PCM jumps in the first 70 seconds. At the first jump the tap moved from 7.272 to 12.192 seconds, then returned to the older audio. The renderer reported insufficient media during advancing video and the engine briefly rebuffered. The VOD packet queue now keeps incoming audio behind queued audio and lets that queue drain while the video packet queue is full. The earlier MKV logs did not record packet order, so they cannot establish that every reported dropout had this cause.

With the queue fix, the Mac probe rendered the AVI through 1:30 and from 10:50 to 11:40 after a seek. Both runs recorded zero PCM timestamp gaps over 200 ms, insufficient-audio renderer samples, or audio rebuffer events. The probe used BoraMin's cache and custom reader with a mounted local source. The iOS, tvOS and macOS targets built and passed the media linkage check. Physical device audio remains to be verified.

The same Mac probe replayed the HEVC/AAC MKV from startup through 0:50 and after a seek from 19:10 to 19:40. Both windows rendered video with no measured audio gaps, renderer starvation, or audio rebuffering. These runs used a mounted local copy, so the earlier intermittent SMB case still needs a live comparison.

Run the Mac diagnostic with:

```sh
python3 tools/run_playback_probe.py failure -- kpop --audio-continuity --audio-start=1166 --audio-end=1178 --aether-diagnostics
```

Both times are required, in playback seconds. The command above covers **19:26–19:38**. For the longer **18:30–21:30** run, use `--audio-start=1110 --audio-end=1290`. The probe reads the SMB fixture and logs decoded audio peaks, timestamp gaps, audio renderer state, and video frame counts. Logs from the investigation are in `build/kpop-audio-continuity.log` and `build/kpop-audio-target-1.log` through `build/kpop-audio-target-3.log`.
