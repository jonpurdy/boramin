import Foundation

private enum CallbackContext {
    @TaskLocal static var active = false
}

@main struct CloudSyncSchedulingTests {
    @MainActor static func main() async {
        // CKSyncEngine marks its delegate callback context using task-local
        // state. Plain Task inherits that state across actor hops and sleeps.
        await CallbackContext.$active.withValue(true) {
            await Task { @MainActor in
                assert(CallbackContext.active, "Control task should inherit callback context")
            }.value
            let scheduled = ICloudSync.engineTask {
                MainActor.assertIsolated()
                assert(!CallbackContext.active, "Scheduled work must leave callback context")
                try? await Task.sleep(for: .milliseconds(1))
                let running = ICloudSync.engineTask {
                    MainActor.assertIsolated()
                    assert(!CallbackContext.active, "Engine operations must stay outside callback context")
                }
                await running.value
            }
            await scheduled.value
            let cancelled = ICloudSync.engineTask {
                do {
                    try await Task.sleep(for: .seconds(60))
                    assertionFailure("Cancelled work must not reach engine operations")
                } catch is CancellationError { }
                catch { assertionFailure("Unexpected cancellation error: \(error)") }
            }
            cancelled.cancel()
            await cancelled.value
        }
        let cached = ICloudSync.Value(id: "favorite", kind: "favorite", fields: ["server": "smb://example.invalid", "share": "Movies", "path": "Folder"], state: "active", updated: Date(), operation: "old")
        var enriched = cached.fields; enriched["connectionID"] = "saved-id"; enriched["identity"] = "existing-favorite-id"
        let snapshot = ICloudSync.Snapshot(kind: "favorite", fields: enriched)
        precondition(ICloudSync.isConnectionMetadataUpgrade(snapshot, from: cached))
        enriched["server"] = "smb://other.invalid"
        precondition(!ICloudSync.isConnectionMetadataUpgrade(.init(kind: "favorite", fields: enriched), from: cached), "Migration must not overwrite newer cloud location fields")
        precondition(!ICloudSync.isConnectionMetadataUpgrade(.init(kind: "favorite", fields: cached.fields), from: cached))
        print("PASS: additive connection-ID migration syncs without overwriting cloud locations")
        print("PASS: sync tasks discard delegate task-local context, retain MainActor isolation and support cancellation")
    }
}
