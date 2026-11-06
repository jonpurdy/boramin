import Foundation
import AMSMB2

/// Equal SMB and HTTP implementations behind the browser's remote-operation boundary.
/// SMB-specific share/reconnection behavior remains in SMBBrowsingService.
final class RemoteSession: @unchecked Sendable {
    let smb: SMB2Manager?
    let http: HTTPFileService?
    var url: URL { smb?.url ?? http!.baseURL }
    var supportsShares: Bool { smb != nil }
    var canDelete: Bool { smb != nil }
    init(smb: SMB2Manager) { self.smb = smb; http = nil }
    init(http: HTTPFileService) { self.http = http; smb = nil }
    static func make(server: String, username: String, domain: String, password: String, timeout: TimeInterval = 20) throws -> RemoteSession {
        guard let url = ConnectionPreferences.connectionURL(server) else { throw PlayerError("Enter a valid connection URL.") }
        if url.scheme == "smb" {
            return RemoteSession(smb: try SMBBrowsingService.makeClient(server: server, username: username, domain: domain, password: password, timeout: timeout))
        }
        return RemoteSession(http: HTTPFileService(baseURL: url, username: username, password: password))
    }
    func listShares(naturalOrder: Bool = true) async throws -> [String] {
        guard let smb else { return [] }
        return try await SMBBrowsingService.listShares(smb, naturalOrder: naturalOrder)
    }
    func connectShare(name: String) async throws {
        if let smb { try await SMBBrowsingService.connectShare(smb, name: name) }
        else { try Task.checkCancellation() }
    }
    func readDirectory(path: String) async throws -> [BrowserEntry] {
        if let smb { return try await SMBBrowsingService.readDirectory(smb, path: path) }
        return try await http!.readDirectory(path: path)
    }
    func attributes(path: String) async throws -> BrowserEntry {
        if let smb {
            let attributes = try await SMBBrowsingService.attributes(smb, path: path)
            var entry = BrowserEntry(name: (path as NSString).lastPathComponent, path: path,
                directory: attributes[.fileResourceTypeKey] as? URLFileResourceType != .regular,
                size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
            entry.modified = (attributes[.contentModificationDateKey] as? Date)?.timeIntervalSince1970 ?? 0
            return entry
        }
        return try await http!.attributes(path: path)
    }
    func removeFile(path: String) async throws {
        guard let smb else { throw PlayerError("HTTP connections are read-only.") }
        try await SMBBrowsingService.removeFile(smb, path: path)
    }
    func removeFileWithSubtitles(entry: BrowserEntry) async throws -> SMBBrowsingService.FileDeletionResult {
        guard let smb else { throw PlayerError("HTTP connections are read-only.") }
        return try await SMBBrowsingService.removeFileWithSubtitles(smb, entry: entry)
    }
    fileprivate func readRange(path: String, size: Int64, range: Range<Int64>) async throws -> Data {
        if let smb { return try await SMBBrowsingService.readRange(smb, path: path, range: range) }
        return try await http!.readRange(path: path, size: size, range: range)
    }

    func openFile(path: String, size: Int64, cancellation: CancellationFlag) async throws -> CachedRemoteFile {
        try Task.checkCancellation()
        if let smb { return CachedRemoteFile(client: smb, path: path, size: size, cancellation: cancellation) }
        return try await http!.openFile(path: path, size: size, cancellation: cancellation)
    }
    func replacement() -> RemoteSession? {
        if let smb { return SMBBrowsingService.replacementSession(for: smb).map { RemoteSession(smb: $0) } }
        return nil // HTTP requests are task-owned; a retry creates a clean session.
    }
    func abort() {
        if let smb { SMBBrowsingService.abort(smb) }
        http?.close()
    }
    func disconnect(gracefully: Bool = true) async {
        await SMBBrowsingService.disconnect(smb, gracefully: gracefully)
        http?.close()
    }
}

// SMB feeds the same cache as HTTP without changing its range/progress behavior.
extension CachedRemoteFile {
    convenience init(client: SMB2Manager, path: String, size: Int64, cancellation: CancellationFlag) {
        self.init(size: size, cancellation: cancellation) { range, cancellation, interrupt, completion in
            client.contents(atPath: path, range: range, progress: { _, _ in !cancellation.cancelled && interrupt?.cancelled != true }, completionHandler: completion)
            return nil
        }
    }
}


/// A sequential, uncached sample on a session owned exclusively by this operation.
enum RemoteSpeedTest {
    struct Sample: Sendable {
        let bytes: Int64
        let elapsed: Duration

        var seconds: Double {
            let parts = elapsed.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        var megabytesPerSecond: Double { Double(bytes) / max(seconds, 1e-9) / 1_000_000 }
    }

    static func run(session: RemoteSession, share: String, path: String,
                    progress: @escaping @MainActor @Sendable (Int64, Double, ContinuousClock.Instant) -> Void) async throws -> Sample {
        defer { session.abort() }
        try await session.connectShare(name: share)
        let file = try await session.attributes(path: path)
        guard !file.directory, file.size > 0 else { throw PlayerError("This file is empty or unavailable.") }
        let limit = min(file.size, 2048 * 1024 * 1024)
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + .seconds(10)

        await progress(0, 0, deadline)
        return try await withThrowingTaskGroup(of: Sample?.self) { group in
            group.addTask {
                try await clock.sleep(until: deadline)
                return nil
            }
            group.addTask {
                var bytes: Int64 = 0
                do {
                    while bytes < limit, clock.now < deadline {
                        let range = bytes..<min(limit, bytes + 2 * 1024 * 1024)
                        let chunk = try await session.readRange(path: path, size: file.size, range: range)
                        bytes += Int64(chunk.count)
                        await progress(bytes, Double(bytes) / Double(limit), deadline)
                        if chunk.count < range.count { break }
                    }
                } catch {
                    // A deadline can interrupt an in-flight read. Only completed chunks count.
                    if !Task.isCancelled { throw error }
                }
                return Sample(bytes: bytes, elapsed: start.duration(to: clock.now))
            }
            defer { group.cancelAll() }
            let first = try await group.next()
            let sample: Sample?
            if let result = first ?? nil {
                sample = result
            } else {
                group.cancelAll()
                sample = try await group.next() ?? nil
            }
            try Task.checkCancellation()
            guard let sample, sample.bytes > 0 else {
                throw PlayerError("No file data arrived during the speed test.")
            }
            return sample
        }
    }
}
