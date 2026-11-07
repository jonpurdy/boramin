# Intermittent audio dropouts in the HEVC/AAC fixture MKV

Reported on Apple TV over SMB and on macOS. Video keeps moving while audio drops for several seconds. The onset varies between plays. The affected MKV is selected by the `kpop` entry in the local playback manifest. On Mac, the file uses AetherEngine's software playback route after the native item is rejected.

- The passages near **19:19** and **19:41** are quiet in the source. Independent decoding confirms audio in **19:26–19:31**, where the user heard silence in BoraMin on one attempt and heard audio in mpv.
- A Mac SMB run from **18:30 to 21:30** captured a **6.3-second** decoded PCM timestamp gap beginning at **18:34.6**. The audio renderer reported insufficient data during the gap while video continued to advance. The run captured decoded audio through **19:26–19:31**.
- Three fresh Mac SMB runs sought directly to **19:26**. One showed no tap gap. Two recorded gaps of **6.8 seconds at 19:34.3** and **7.0 seconds at 19:36.6**. The second run also showed insufficient audio renderer data with advancing video. The exact **19:26–19:31** dropout was not reproduced.

The decoded PCM tap runs before audio output and may drop buffers under load. The renderer telemetry corroborates an audio delivery problem in the runs above. The cause and exact audible duration are unresolved. Apple TV has user observations but no matching diagnostic capture.

Run the Mac diagnostic with:

```sh
python3 tools/run_playback_probe.py failure -- kpop --audio-continuity --audio-start=1166 --audio-end=1178 --aether-diagnostics
```

Both times are required, in playback seconds. The command above covers **19:26–19:38**. For the longer **18:30–21:30** run, use `--audio-start=1110 --audio-end=1290`. The probe reads the SMB fixture and logs decoded audio peaks, timestamp gaps, audio renderer state, and video frame counts. Logs from the investigation are in `build/kpop-audio-continuity.log` and `build/kpop-audio-target-1.log` through `build/kpop-audio-target-3.log`.
