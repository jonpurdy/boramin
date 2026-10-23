# Playback diagnostics

BoraMin uses Apple's unified logging (`OSLog.Logger`) on iOS, tvOS and macOS. The subsystem is **`com.example.BoraMin`**. Categories are **Playback**, **Streaming**, **Audio**, **Browser** and **iCloud**.

Native playback selects the first audio option that AVFoundation considers playable and whose codec appears in AudioToolbox's available decoder list. If audio tracks exist but none qualify, playback shows the standard error presentation; videos without audio remain playable. AVKit owns the track menu, so unsupported entries cannot be added as custom disabled rows. Codec availability does not guarantee support for every profile or damaged stream. The demuxed MKV/WebM path is unchanged.

## What is logged

- Playback open/close and completion, with a random session identifier to correlate events.
- Source video codec, resolution/FPS, confirmed VP9 hardware decoding and decoder OSStatus errors.
- Player state changes, waiting reasons, buffer-empty/likely-to-keep-up flags, stall notifications, seeks and saved-position restoration. Native AVPlayer error-log entries include status codes; free-form error details remain private.
- Every approximately 15 seconds during an active player session: playback position, player state, process resident bytes, compressed-cache occupancy/capacity, fetched bytes and thermal state.
- For the sample-buffer video path, Apple’s public renderer metrics every approximately 15 seconds: total/dropped/corrupted frames, accumulated display delay, optimized-compositing frames, and queued video timestamp versus its clock. These counters may reset on flush; unavailable metrics are recorded at info level.
- On tvOS, display-criteria matching enabled/switching status and the requested source FPS when playback appears. This does not itself prove the HDMI output refresh rate.
- iOS/tvOS player memory warnings when UIKit delivers them. System termination can happen without a preceding warning.
- SMB read errors and player failures, including numeric error codes where available.
- iCloud sync completion/failure codes.

Lifecycle/status entries use `notice`, failures use `error`, and memory warnings use `warning`. Frequent frame, HTTP range, audio-request and bookmark-checkpoint details use `debug`; experimental segment statistics use `info`. Explicit automated test/probe markers retain their stdout output. Logging is independent of the **Show Debug Info** overlay setting.

Media titles and free-form error details use private/default string privacy. Passwords, server addresses and media paths are not deliberately logged as public values. Public session IDs are random per playback preparation, not user or file identifiers. Technical numeric metrics and fixed system waiting/error identifiers remain visible.

## Viewing logs

In macOS **Console**, select the Mac or an available connected device, start streaming, and filter for subsystem `com.example.BoraMin`. Enable info/debug messages when investigating detailed request activity. Xcode's debug console also displays unified logs during a debug run; these new messages are not plain stdout markers.

For the Mac's stored logs:

```sh
log show --last 30m --style compact --predicate 'subsystem == "com.example.BoraMin"'
```

For live Mac logging, including debug messages:

```sh
log stream --level debug --predicate 'subsystem == "com.example.BoraMin"'
```

These terminal commands inspect the Mac, not a remote Apple TV/iPhone. Use the device's supported Console/Xcode diagnostic tools for device logs. Preserve the approximate wall-clock time, device/OS and app build when collecting a report.

## Crashes and unexpected exits

Unified logs provide context; they are not a replacement for the system crash or memory-termination report. TestFlight crash reports appear in **Xcode → Window → Organizer → Crashes** after Apple receives/processes them. Keep the matching release archive and dSYMs for symbolication. For directly installed apps or reports absent from Organizer, inspect the device logs through **Window → Devices and Simulators**.

An exit to the Home Screen may be a crash, watchdog termination or memory-pressure termination (jetsam). A frozen frame with continuing audio may not produce a crash report at all. Resident-byte readings and cache occupancy are clues, not a precise prediction of a device's jetsam limit or a cap on total playback memory.

Apple controls unified-log storage, retention and privacy redaction. Historical debug messages may be unavailable, and an abrupt kill may prevent the final message from being recorded. Logs are not automatically attached to TestFlight crash reports; collect the surrounding system logs separately when needed. No custom crash handler, log-upload service or user-facing log exporter is added.

References: [Apple logging](https://developer.apple.com/documentation/os/logging/), [acquiring crash reports](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs), [jetsam reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports).

## Debug overlay resource statistics

When Show Debug Info is enabled, the overlay samples app CPU and resident memory once per second. CPU 100% means one CPU core; multicore usage can exceed 100%. These are app-process measurements, not hardware-decoder utilization or all memory used by system media services. The first CPU sample is unavailable until an interval has elapsed.

The sample-buffer renderer supplies dropped/total frame counts, which can reset on seek/flush. Native AVPlayer uses available access-log dropped-frame counts; total frames are unavailable. Missing statistics display Unavailable rather than zero. These counters measure reported drops, not every possible visible stutter.
