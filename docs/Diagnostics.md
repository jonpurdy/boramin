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

### Physical Apple TV navigation exits without a debugger

Collect device reports directly before relying on TestFlight. Apple's Crashes organizer does not include jetsam, watchdog, thermal or invalid-code-signature events. Simulator success does not rule out a physical-device failure.

1. Record the exit time with timezone, app version/build, tvOS version, last navigation action, and whether the app was foregrounded or returning from the background. Leave the installed app/data intact.
2. Wake the paired Apple TV. If the diagnostic connection fails, open **Settings → Remotes and Devices → Remote App and Devices** and retry. Listing a paired device as available does not guarantee its diagnostic tunnel is ready.
3. With Xcode's supported `devicectl`, list the device's **systemCrashLogs** recursively. Use a new local output directory for each capture; these commands do not attach a debugger, launch/terminate the app or delete device reports:

   ```sh
   xcrun devicectl --timeout 20 list devices
   capture_dir="build/AppleTVMonitoring/navigation-$(date +%Y%m%d-%H%M%S)"
   mkdir -p "$capture_dir"
   # Replace DEVICE_ID with the Apple TV identifier from the device listing.
   xcrun devicectl --timeout 30 device info files \
     --device DEVICE_ID --domain-type systemCrashLogs --recurse \
     --json-output "$capture_dir/crash-files.json"
   # Replace REPORT.ips with an exact relativePath from result.files in that JSON.
   xcrun devicectl --timeout 30 device copy from \
     --device DEVICE_ID --domain-type systemCrashLogs \
     --source REPORT.ips --destination "$capture_dir/REPORT.ips"
   ```

   Inspect `BoraMin-*.ips`, `JetsamEvent-*.ips`, and reports from system processes near the exit time. Use JSON output for automation, rather than parsing the human-readable table. Preserve raw reports and matching archives/dSYMs locally under ignored `build/`.
4. For a crash, inspect exception, termination namespace/reason, faulting thread and app binary UUID. Symbolicate with matching symbols. For jetsam, find BoraMin in `processes` and check whether **that entry has a `reason`**. Merely appearing in the process list or being the largest process is not proof of termination. Record `states`: a suspended-background eviction does not establish a foreground navigation crash. Memory in bytes is `rpages × pageSize`; on the reports collected here, `pageSize` is under `memoryStatus`. Jetsam reports have no app exception backtrace. A system `stacks-*.ips` report with reason `stackshot via sysdiagnose` is a snapshot, not itself evidence that BoraMin crashed.
5. If the corresponding report is absent, capture the Apple TV in **Console** before reproducing. Search for `BoraMin` across processes, rather than restricting the capture to the app subsystem: RunningBoard, FrontBoard/PineBoard, ReportCrash and kernel messages may explain the termination. Record the exact exit time and preserve the surrounding messages, including exit/termination reasons. Absence of a retained report does not rule out a termination.

For recent historical device logs, the installed macOS `log` tool supports the following command, which requires administrator authentication in Terminal. This is a remote-device collection, unlike the Mac-only `log show` examples above:

```sh
sudo /usr/bin/log collect --device-name 'APPLE_TV_NAME' --last 30m \
  --output "$capture_dir/appletv.logarchive"
```

If collection fails or the device is unavailable, use Console's live device stream and reproduce again. Do not substitute a Mac log archive for an Apple TV capture.

## Debug overlay resource statistics

When Show Debug Info is enabled, the overlay samples app CPU and resident memory once per second. CPU 100% means one CPU core; multicore usage can exceed 100%. These are app-process measurements, not hardware-decoder utilization or all memory used by system media services. The first CPU sample is unavailable until an interval has elapsed.

The sample-buffer renderer supplies dropped/total frame counts, which can reset on seek/flush. Native AVPlayer uses available access-log dropped-frame counts; total frames are unavailable. Missing frame counts display `?` rather than zero; unavailable CPU/memory samples retain their unavailable label. These counters measure reported drops, not every possible visible stutter.

## Intermittent SMB opening errors

Connection logs include the phase (`shares` or `directory`), attempt number, elapsed time, and error domain/code, without server addresses or credentials. Read-only connection opening retries once with a fresh manager for transient I/O/reset/timeout errors. Permission, authentication and missing-path failures are surfaced without automatic retry. A failed manager is closed before retrying. This is bounded recovery, not proof that the underlying server/library/network issue is resolved.

October 27: the installed Mac app logged POSIX I/O error 5; a model stress run also encountered permission error 1. Twenty direct enumeration attempts passed, and the subsequent model run passed 40 opening/reconnection attempts without needing recovery. Live GUI failures still need correlation with the new attempt logs.

## October 30 session findings

- Show Debug Info can be toggled during native playback: tvOS transport Settings menu, Mac AVKit action menu, and an iOS Settings menu beside Audio & Subtitles. These use the existing saved preference and take effect immediately.
- The Mac connection failure after updating was confirmed in system logs as `Local network prohibited`, while TCP port 445 was reachable on both servers. Restoring macOS Local Network permission resolved it; no SMB code change was needed.
- Apple TV list-navigation/background-reopen exits remain unexplained. No useful termination stack was captured and no crash fix was applied. Prefer reproducing in a TestFlight-installed build and collecting its crash report. The directly installed developer build does not report through TestFlight. No persistent file logger or report-on-relaunch dialog was implemented.

## October 31 Apple TV navigation capture

Direct device retrieval worked without a debugger. The recursive `systemCrashLogs` listing contained 13 jetsam reports. BoraMin was explicitly a victim of `sustained-memory-pressure` on October 23 at 21:11:44 EDT and October 24 at 21:47:16 EDT, with `states: [suspended]` in both. These establish historical background eviction, not a foreground navigation crash. The latest retained BoraMin exception report was still October 23, with a CloudKit assertion stack.

The user then reproduced the navigation/background-return exit while browsing an SMB server during a live Console capture on October 31 at approximately 09:48:33 EDT. PineBoard logged at **09:48:32.150466 EDT**:

```text
[app<com.example.BoraMin>:8356] Process exited: <RBSProcessExitContext| specific, status:<RBSProcessExitStatus| domain:signal(2) code:SIGPIPE(13)>>.
```

This reproduced exit was a SIGPIPE termination. No new crash or jetsam report appeared in the immediate post-reproduction device listing. Apple's [networking guidance](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/CommonPitfalls/CommonPitfalls.html) explains that an unhandled SIGPIPE can terminate a process when it writes to a closed connection, and documents per-socket `SO_NOSIGPIPE` protection. Source inspection found a candidate in vendored libsmb2: `smb2_write_to_socket` calls `writev`, while `connect_async_ai` creates its sockets without `SO_NOSIGPIPE`. The capture identifies the terminating signal, not the originating call stack; the SMB path is a candidate requiring a targeted fix/test and a physical-device retest, not a verified source attribution or completed fix.

Reports, exact Console excerpts and findings are preserved under ignored `build/AppleTVMonitoring/navigation-2026-10-31/`. Historical unified-log export was unavailable because `log collect` required administrator authentication; the decisive evidence came from the live device stream instead. No app code or installed app was changed during this investigation.

### Socket correction following the capture

Outgoing libsmb2 sockets now enable Apple's per-socket `SO_NOSIGPIPE` before connecting. A write to a dead connection follows the existing `EPIPE`/SMB error path instead of killing the process. If the socket option fails, connection setup closes that socket and reports an error. The change does not install a global signal handler.

`python3 tools/test_smb_socket.py` reproduced signal 13 in the unpatched production SMB write path using a reset loopback peer. With the correction, the same test survives and checks `EPIPE` and the existing SMB write error. This establishes the socket failure and its correction in a controlled host test, not the originating call stack from the Apple TV capture. The user subsequently reported that the Apple TV issue appears fixed in an initial retest. That is provisional device feedback; older suspended jetsam events are unaffected.

Validation passed: all three platform Release builds, the main regression suite, and sequential offline browsing/cancellation probes. The generated diagnostic app was removed afterward; detailed output is under ignored `build/SMBSocketTests/`. The controlled socket regression ran on macOS, not the simulator. On October 31, the patched development-signed 0.5 (5) Release build was installed directly on the paired Apple TV at the user's request; `tvos-install.json` records success. Signature verification with host trust access passed, and the installed source bundle's executable contains the socket protection. Following installation, the user reported that the issue appears fixed; longer-term recurrence has not been ruled out. No upload was performed.

### Review of the two historical BoraMin jetsam victims

Both reports describe **suspended background eviction under sustained system memory pressure**, with BoraMin at priority 0. Neither records a `per-process-limit` termination. Infuse was `active, frontmost` and the largest reported process in both; that does not by itself identify an Infuse defect.

| Event (EDT) | BoraMin at eviction | BoraMin lifetime peak | Infuse at event |
| --- | --- | --- | --- |
| October 23, 21:11:44 | 33.95 MiB | 181.31 MiB | 1008.50 MiB |
| October 24, 21:47:16 | 162.00 MiB | 459.66 MiB | 1038.23 MiB |

These values use `rpages` and `lifetimeMax` multiplied by `memoryStatus.pageSize` (16,384 bytes). Each report has 60 process entries carrying `sustained-memory-pressure` reasons, so BoraMin was among many background/system victims. Its reported resident size stayed unchanged across the preceding approximately 91-second and 61-second report sequences, respectively. This shows no growth within those snapshots, but cannot rule out a leak elsewhere in the process lifetime. The reports contain no allocation breakdown to attribute the 162 MiB to a cache or decoder.

Current source review found no explicit memory-pressure purge in the shared 128 MiB compressed cache. The native player saves position on background and logs memory warnings; those handlers do not trim that cache. Playback dismissal stops/releases the transport and player resources, while the software playback view explicitly stops/closes on background. A retained full cache is a plausible contributor to the larger background footprint, not a finding established by these reports.

No app behavior changed for this review. The next useful measurement is cache occupancy and app footprint before/after playback dismissal and backgrounding on the physical TV, followed by cache purging if retention is confirmed. Preserve normal playback cache locking/capacity and routing. A smaller background footprint may help, but cannot guarantee that tvOS keeps a suspended app alive. Detailed report analysis is under ignored `build/AppleTVMonitoring/navigation-2026-10-31/jetsam-analysis.md`.

### Cache cleanup on video exit

Following the review, the user requested explicit cleanup on video exit. `StreamingSession.stop()` now cancels its source and schedules removal of all compressed cache blocks, LRU entries and diagnostic block history. Cleanup takes the existing cache lock on a worker queue, after cancellation releases any pending reader, so player dismissal does not wait for a remote read on the main thread. Cache occupancy becomes zero; transfer totals remain available for diagnostic logging. Cancelled sources reject subsequent reads and cannot refill from late callbacks. A Streaming-category notice records the number of cache bytes released.

The shared stop path covers SMB and HTTP(S) streams through native, VP9 and Aether playback teardown. A native/software presentation transition that preserves the existing Aether session does not stop that transport or clear its active cache. This change does not purge on pause alone, change active playback capacity/locking, or guarantee an immediate matching drop in the operating system's reported process footprint. Physical Apple TV memory/reopen verification remains separate from the isolated cache tests.

Validation passed: the cancellation probe's retained-cache/stalled-read/late-completion checks, the main suite, offline browsing, and all three platform Release builds. The generated diagnostic app was removed; logs are under ignored `build/CacheCleanup/`. At the user's request, the development-signed 0.5 (5) Release build containing cache cleanup and the SIGPIPE fix was subsequently installed on the paired Apple TV on October 31; `build/CacheCleanup/tvos-install.json` records success. Device cache/memory behavior has not yet been verified. No upload was performed.
