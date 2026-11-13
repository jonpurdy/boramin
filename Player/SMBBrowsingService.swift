import Foundation
import AMSMB2

/// SMB transport operations. Navigation, preferences and presentation belong to Browser.
/// Short-lived operations can use a separate manager without changing the browsing session.
@MainActor final class SMBBrowsingService {
    var client: SMB2Manager?

    nonisolated static func makeClient(server: String, username: String, domain: String, password: String,
                                       timeout: TimeInterval = 20) throws -> SMB2Manager {
        let raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw.contains("://") ? raw : "smb://\(raw)"),
              url.scheme == "smb", let hostname = url.host, !hostname.isEmpty,
              url.user == nil, url.password == nil, url.path.isEmpty || url.path == "/" else {
            throw PlayerError("Enter a server name or IP address, such as smb://nas.local. Enter the share separately.")
        }
        let credential = URLCredential(user: username.isEmpty ? "guest" : username, password: password, persistence: .none)
        guard let manager = SMB2Manager(url: url, domain: domain, credential: credential) else {
            throw PlayerError("Invalid SMB server.")
        }
        manager.timeout = timeout
        return manager
    }

    nonisolated static func listShares(_ manager: SMB2Manager, naturalOrder: Bool = true) async throws -> [String] {
        let shares: [(name: String, comment: String)] = try await CancellableOperation.run(interrupt: { abort(manager) }) { completion in
            manager.listShares(completionHandler: completion)
        }
        let names = shares.map(\.name)
        return naturalOrder ? names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } : names.sorted()
    }

    nonisolated static func connectShare(_ manager: SMB2Manager, name: String) async throws {
        // AMSMB2 checks the session with SMB echo and reconnects expired/dropped sessions.
        let _: Void = try await CancellableOperation.run(interrupt: { abort(manager) }) { completion in
            manager.connectShare(name: name) { error in
                completion(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    nonisolated static func readDirectory(_ manager: SMB2Manager, path: String) async throws -> [BrowserEntry] {
        entries(from: try await directoryAttributes(manager, path: path), path: path)
    }

    nonisolated static func directoryAttributes(_ manager: SMB2Manager, path: String) async throws -> [[URLResourceKey: any Sendable]] {
        try await CancellableOperation.run(interrupt: { abort(manager) }) { completion in
            manager.contentsOfDirectory(atPath: path, completionHandler: completion)
        }
    }

    nonisolated static func entries(from contents: [[URLResourceKey: Any]], path: String) -> [BrowserEntry] {
        contents.compactMap { attributes in
            guard let name = attributes[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            var entry = BrowserEntry(name: name, path: path.isEmpty ? name : "\(path)/\(name)",
                directory: attributes[.fileResourceTypeKey] as? URLFileResourceType == .directory,
                size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
            entry.modified = (attributes[.contentModificationDateKey] as? Date)?.timeIntervalSince1970 ?? 0
            if let created = attributes[.creationDateKey] as? Date, created.timeIntervalSince1970 != 0 {
                entry.created = created
            }
            return entry
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func attributes(_ manager: SMB2Manager, path: String) async throws -> [URLResourceKey: any Sendable] {
        try await CancellableOperation.run(interrupt: { abort(manager) }) { completion in
            manager.attributesOfItem(atPath: path, completionHandler: completion)
        }
    }

    nonisolated static func removeFile(_ manager: SMB2Manager, path: String) async throws {
        let _: Void = try await CancellableOperation.run(interrupt: { abort(manager) }) { completion in
            manager.removeFile(atPath: path) { error in
                completion(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    struct FileDeletionResult: Sendable {
        var removedPaths: [String]
        var failedSubtitleNames: [String] = []
    }

    nonisolated static func associatedSubtitles(for video: BrowserEntry, in entries: [BrowserEntry]) -> [BrowserEntry] {
        guard !video.directory, video.playable else { return [] }
        let folder = (video.path as NSString).deletingLastPathComponent
        let siblings = entries.filter { ($0.path as NSString).deletingLastPathComponent == folder && !$0.directory }
        return siblings.filter { subtitle in
            guard ExternalSubtitleFiles.matches(videoName: video.name, subtitleName: subtitle.name) else { return false }
            // Check ownership per subtitle: Movie.en.mkv also uses Movie.en.srt.
            // Ignore case conservatively for sharing protection on SMB servers.
            return !siblings.contains { other in
                other.path != video.path && other.playable &&
                ExternalSubtitleFiles.matches(videoName: other.name.lowercased(), subtitleName: subtitle.name.lowercased())
            }
        }
    }

    nonisolated static func validateDeletion(expected: BrowserEntry, attributes: [URLResourceKey: any Sendable]) throws {
        guard !expected.directory,
              attributes[.fileResourceTypeKey] as? URLFileResourceType == .regular,
              let size = attributes[.fileSizeKey] as? NSNumber, size.int64Value == expected.size else {
            throw PlayerError("This file has changed. Refresh its folder in Connections before deleting it.")
        }
    }

    nonisolated static func removeFileWithSubtitles(_ manager: SMB2Manager, entry: BrowserEntry) async throws -> FileDeletionResult {
        let current = try await attributes(manager, path: entry.path)
        try Task.checkCancellation()
        try validateDeletion(expected: entry, attributes: current)
        // Discover from a fresh listing, not a filtered or stale browser snapshot.
        // A listing failure aborts before any deletion.
        let subtitles: [BrowserEntry]
        if entry.playable {
            let siblings = try await readDirectory(manager, path: (entry.path as NSString).deletingLastPathComponent)
            subtitles = associatedSubtitles(for: entry, in: siblings)
        } else { subtitles = [] }
        return try await executeDeletion(path: entry.path, subtitles: subtitles) { path in
            try await removeFile(manager, path: path)
        }
    }

    nonisolated static func executeDeletion(path: String, subtitles: [BrowserEntry],
        remove: @Sendable (String) async throws -> Void) async throws -> FileDeletionResult {
        try Task.checkCancellation()
        try await remove(path)
        var result = FileDeletionResult(removedPaths: [path])
        for subtitle in subtitles {
            do {
                try Task.checkCancellation()
                try await remove(subtitle.path)
                result.removedPaths.append(subtitle.path)
            } catch {
                // The video is already gone. Return that success even when
                // some sidecars fail, so history and visible rows stay accurate.
                result.failedSubtitleNames.append(subtitle.name)
            }
        }
        return result
    }

    nonisolated static func readRange(_ manager: SMB2Manager, path: String, range: Range<Int64>) async throws -> Data {
        let cancellation = CancellationFlag()
        return try await CancellableOperation.run(interrupt: {
            cancellation.cancel()
            abort(manager)
        }) { completion in
            manager.contents(atPath: path, range: range, progress: { _, _ in !cancellation.cancelled },
                             completionHandler: completion)
        }
    }

    nonisolated static func replacementSession(for manager: SMB2Manager) -> SMB2Manager? {
        // NSCopying retains connection settings/credentials, never the old socket or queue.
        manager.copy() as? SMB2Manager
    }

    /// Public AMSMB2 API: interrupt outstanding work rather than waiting for the queue to drain.
    nonisolated static func abort(_ manager: SMB2Manager) {
        manager.disconnectShare(gracefully: false) { _ in }
    }

    nonisolated static func disconnect(_ manager: SMB2Manager?, gracefully: Bool = true) async {
        if Task.isCancelled { if let manager { abort(manager) }; return }
        try? await manager?.disconnectShare(gracefully: gracefully)
    }
}
