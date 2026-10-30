import Foundation

private final class Callback<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Value, Error>) -> Void)?
    private var interrupts = 0
    var started: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    var interruptCount: Int { lock.lock(); defer { lock.unlock() }; return interrupts }
    func start(_ value: @escaping @Sendable (Result<Value, Error>) -> Void) { lock.lock(); completion = value; lock.unlock() }
    func interrupt() { lock.lock(); interrupts += 1; lock.unlock() }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let callback = completion; lock.unlock()
        callback?(result)
    }
}

@main @MainActor struct BrowserCancellationTests {
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PlayerError("Cancellation regression timed out")
    }
    static func main() async throws {
        let normal: Int = try await CancellableOperation.run(interrupt: {}) { $0(.success(42)) }
        precondition(normal == 42)
        let beforeStart = Callback<Int>()
        let alreadyCancelled = Task { try await CancellableOperation.run(interrupt: { beforeStart.interrupt() }, start: beforeStart.start) }
        alreadyCancelled.cancel()
        do { _ = try await alreadyCancelled.value; preconditionFailure("Pre-cancelled operation started") }
        catch is CancellationError { }
        precondition(!beforeStart.started)
        let callback = Callback<Int>()
        let task = Task {
            try await CancellableOperation.run(interrupt: { callback.interrupt() }, start: callback.start)
        }
        try await wait { callback.started }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled waiter returned success") }
        catch is CancellationError { }
        precondition(callback.interruptCount == 1)
        callback.finish(.success(1))
        callback.finish(.failure(POSIXError(.ETIMEDOUT)))
        precondition(callback.interruptCount == 3)
        print("PASS: cancellation releases a stalled callback waiter; late successes/errors cannot resume it twice")

        for _ in 0..<100 {
            let race = Callback<Int>()
            let pending = Task { try await CancellableOperation.run(interrupt: { race.interrupt() }, start: race.start) }
            try await wait { race.started }
            DispatchQueue.global().async { race.finish(.success(1)) }
            pending.cancel()
            do { _ = try await pending.value } catch is CancellationError { }
        }
        print("PASS: concurrent completion/cancellation races")

        let suite = "BoraMinCancellationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = Browser(connections: ConnectionPreferences(defaults: defaults), metadataCache: MediaMetadataCache(defaults: defaults))
        var actionStarted = false
        browser.perform("Cancelled before start") { actionStarted = true }
        browser.cancel()
        try await Task.sleep(for: .milliseconds(20))
        precondition(!actionStarted && !browser.busy)
        for lateFailure in [false, true] {
            let browsingSession = try SMBBrowsingService.makeClient(server: "smb://127.0.0.1", username: "guest", domain: "", password: "", timeout: 5)
            browser.client = browsingSession; browser.connected = true
            let old = Callback<String>(), next = Callback<String>()
            browser.path = "original"
            browser.perform("Old operation") {
                let value = try await CancellableOperation.run(interrupt: { old.interrupt() }, start: old.start)
                try Task.checkCancellation()
                browser.path = value
            }
            try await wait { old.started }
            let flag = browser.cancellation
            // A rejected request while busy must not replace the operation's read-cancellation flag.
            browser.play(BrowserEntry(name: "unused.mp4", path: "unused.mp4", directory: false, size: 1))
            precondition(browser.cancellation === flag)
            browser.cancel()
            precondition(!browser.busy && browser.status.isEmpty && flag.cancelled)
            precondition(browser.connected && browser.client !== browsingSession && browser.client?.url == browsingSession.url && browser.client?.timeout == 5)
            browser.perform("New operation") {
                let value = try await CancellableOperation.run(interrupt: { next.interrupt() }, start: next.start)
                try Task.checkCancellation()
                browser.path = value
            }
            try await wait { next.started }
            old.finish(lateFailure ? .failure(POSIXError(.ETIMEDOUT)) : .success("stale"))
            try await Task.sleep(for: .milliseconds(20))
            precondition(browser.busy && browser.status == "New operation" && browser.path == "original" && browser.error == nil)
            next.finish(.success("new"))
            try await wait { !browser.busy }
            precondition(browser.path == "new" && browser.error == nil)
            let completedFlag = browser.cancellation
            browser.cancel()
            precondition(!completedFlag.cancelled) // Cancel outside preparation must not stop playing media.
        }
        print("PASS: explicit Cancel clears busy state, replaces the cancelled session, blocks stale results/errors, and preserves the newer operation")

        let delayedError = Callback<Void>(), following = Callback<Void>()
        browser.perform("Ignores task cancellation") {
            try await withCheckedThrowingContinuation { delayedError.start($0.resume(with:)) }
        }
        try await wait { delayedError.started }
        browser.cancel()
        browser.perform("Following operation") {
            let _: Void = try await CancellableOperation.run(interrupt: {}, start: following.start)
        }
        try await wait { following.started }
        delayedError.finish(.failure(POSIXError(.EIO)))
        try await Task.sleep(for: .milliseconds(20))
        precondition(browser.error == nil && browser.busy && browser.status == "Following operation")
        following.finish(.success(()))
        try await wait { !browser.busy }
        print("PASS: an uncooperative old task cannot show an error or clear a newer task's busy state")

        // Reproduce a previous connection screen without starting network work.
        let saved = SMBConnection(id: "home-navigation", fields: ["server": "smb://127.0.0.1"])!
        browser.openConnection(saved)
        browser.cancel() // Cancel before the model-owned task starts.
        precondition(!browser.showingConnections)
        browser.error = POSIXError(.ETIMEDOUT).localizedDescription
        browser.showConnections()
        await browser.automaticallyConnect() // The newly presented screen's foreground task.
        precondition(browser.showingConnections && !browser.busy && !browser.connected)
        precondition(browser.client == nil && browser.error == nil && browser.connectionError == nil)
        precondition(browser.share.isEmpty && browser.path.isEmpty && browser.connectionID == saved.id)
        print("PASS: returning to Connections clears previous browsing/error state and suppresses foreground reconnect")

        let manager = try SMBBrowsingService.makeClient(server: "smb://127.0.0.1", username: "guest", domain: "", password: "")
        let normalFlag = CancellationFlag()
        let normalSource = SMBRemoteFile(client: manager, path: "unused.mp4", size: 100, cancellation: normalFlag)
        let transport = try StreamingSession(source: normalSource, fileExtension: "mp4")
        try await transport.start()
        precondition((transport.sourceURL.port ?? 0) > 0)
        transport.stop()
        precondition(normalFlag.cancelled)
        print("PASS: normal streaming listener starts and stops without reading SMB")
        let flag = CancellationFlag(); flag.cancel()
        let source = SMBRemoteFile(client: manager, path: "unused.mkv", size: 100, cancellation: flag)
        do { _ = try source.read(offset: 0, count: 10); preconditionFailure("Cancelled blocking reader started") }
        catch is CancellationError { }
        let preparation = Task {
            try await PreparedMedia.stream(client: manager, path: "unused.mkv", size: 100, title: "Cancellation test", directory: Browser.cache, cancellation: CancellationFlag())
        }
        preparation.cancel()
        do { _ = try await preparation.value; preconditionFailure("Cancelled preparation returned media") }
        catch is CancellationError { }
        print("PASS: cancelled reads/preparation do not open a source or present late media")
    }
}
