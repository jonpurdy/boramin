# CloudKit termination during playback — October 23, 2026

## Evidence

The Apple TV developer build exited to the Home Screen while playing a 3840×1600 HEVC MKV at 23.976 fps. The user also reported frequent brief picture stutters with uninterrupted audio before the exit.

The live `devicectl --console` capture recorded a fatal CloudKit assertion: an operation that can generate delegate events was awaited from an inherited CKSyncEngine delegate context. The process terminated with signal 5. The device report `BoraMin-2026-10-23-084052.ips` confirms **EXC_BREAKPOINT / SIGTRAP**, with `ICloudSync.runSync()` and the task created in `ICloudSync.synchronize()` in the faulting stack. This particular termination was not a jetsam report or a reported video-decoder failure.

Raw evidence is retained in ignored `build/AppleTVMonitoring/`, including the process console, device crash report and captured playback-health entries. It may contain private device information; do not commit the raw reports.

## Cause and change

`handleEvent` calls local change capture, which may schedule another sync. Ordinary `Task` inherits task-local context, including when a task sleeps or hops to MainActor. The prior scheduled/running tasks could therefore carry CloudKit's delegate marker into a later `fetchChanges()` or `sendChanges()` call.

The scheduling, running and cancellation entry points now use a shared `engineTask` factory backed by **`Task.detached` with an explicit MainActor closure**. This discards inherited task-local delegate context while retaining actor isolation for mutable application state. Delegate methods still handle/return their events normally; they do not await the independently scheduled engine operations.

This uses Swift concurrency and the existing supported CloudKit APIs. No crash handler, schema change, data migration, or playback-pipeline change is involved. [Apple's delegate guidance](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8) explains the restriction on operations that generate additional delegate callbacks.

## Validation and limits

- The targeted host regression test uses a TaskLocal marker to reproduce context inheritance. It confirms ordinary Task inherits the marker, the actual production task factory clears it even for delayed/nested work, MainActor isolation is retained, and cancellation still prevents delayed work from proceeding.
- iOS, tvOS and macOS Release builds passed.
- The regression test is included in `tools/run_tests.py`; the entire codec suite was not repeated for this scheduling-only change.
- Installed and launched the fixed developer build on Apple TV. Console confirmed an initial successful iCloud sync (`33` records, `0` pending) at approximately 08:44 EDT. Long-duration device playback with the fix still needs observation. This fix addresses the confirmed CloudKit termination; it does not establish the cause of the picture stutters.
