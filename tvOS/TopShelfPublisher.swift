#if os(tvOS)
import Foundation
import TVServices
import OSLog
import CryptoKit
import Combine

/// Shared presentation state for the native tvOS activity indicator, including sheets.
@MainActor final class TVBackgroundActivity: ObservableObject {
    static let shared = TVBackgroundActivity()
    @Published var loading = false
    @Published var playing = false
    @Published var artwork = false
}

extension Notification.Name {
    static let topShelfOpenItem = Notification.Name("BoraMin.topShelfOpenItem")
}

@MainActor enum TopShelfPublisher {
    private static let logger = Logger(subsystem: "com.example.BoraMin", category: "TopShelf")

    private static var foreground = false
    private static var browsingBusy = false
    private static var attempted: Set<String> = []
    private static var task: Task<Void, Never>?
    private static var cancellation: CancellationFlag?
    private static var session: RemoteSession?

    static func setForeground(_ active: Bool) {
        guard foreground != active else { refresh(force: active); return }
        foreground = active
        logger.info("Artwork foreground state: \(active)")
        if active { attempted.removeAll() }
        else { stopReads() }
        refresh(force: active)
    }
    static func setBrowsingBusy(_ busy: Bool) {
        browsingBusy = busy
        if busy { stopReads() }
        else { refresh() }
    }
    private static func stopReads() {
        cancellation?.cancel()
        task?.cancel()
        session?.abort() // This is always a dedicated artwork connection.
    }
    private static func key(_ file: PlaybackFile) -> String? {
        guard let server = URL(string: file.server) else { return nil }
        return MediaMetadataCache.key(server: server, connectionID: file.connectionID, share: file.share, path: file.path, size: file.size)
    }
    private static func publishedArtwork(_ file: PlaybackFile?) -> String? {
        guard let file, let key = key(file), let png = ThumbnailCache.shared.data(for: key) else { return nil }
        let filename = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() + ".png"
        guard let url = TopShelfSnapshot.artworkURL(filename) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try png.write(to: url, options: .atomic) }
            return filename
        } catch { return nil }
    }
    private static func scheduleReads() {
        guard foreground, !browsingBusy, task == nil,
              PlaybackPositions.shared.watching().contains(where: { item in
                  item.file.flatMap { key($0) }.map { !attempted.contains($0) } ?? false
              }) else { return }
        logger.info("Starting Watching artwork checks")
        TVBackgroundActivity.shared.artwork = true
        task = Task { @MainActor in
            defer {
                task = nil; cancellation = nil; session = nil
                TVBackgroundActivity.shared.artwork = false
                refresh()
            }
            while foreground && !browsingBusy && !Task.isCancelled {
                guard let file = PlaybackPositions.shared.watching().compactMap(\.file)
                    .first(where: { key($0).map { !attempted.contains($0) } ?? false }),
                      let key = key(file) else { break }
                attempted.insert(key)
                await loadArtwork(file, key: key)
                if Task.isCancelled { attempted.remove(key); break }
                // Publish each completed image without waiting for every server.
                refresh()
            }
        }
    }
    private static func loadArtwork(_ file: PlaybackFile, key: String) async {
        let connections = ConnectionPreferences.shared
        guard let saved = connections.resolve(id: file.connectionID, server: file.server, username: file.username,
                domain: file.domain, share: file.share),
              let remote = try? RemoteSession.make(server: saved.server, username: saved.username, domain: saved.domain,
                password: connections.password(connectionID: saved.id) ?? "", timeout: 5) else { return }
        let flag = CancellationFlag()
        cancellation = flag; session = remote
        do {
            try await remote.connectShare(name: file.share)
            let entry = try await remote.attributes(path: file.path)
            guard !Task.isCancelled, !flag.cancelled else { await remote.disconnect(); return }
            if entry.directory || entry.size != file.size {
                // A saved bookmark must not keep displaying artwork from a replaced file.
                ThumbnailCache.shared.save(EmbeddedArtworkResult(png: nil), for: key, modified: entry.modified)
            } else if !ThumbnailCache.shared.contains(key, modified: entry.modified) {
                ThumbnailCache.shared.invalidate(key)
                if let result = await MetadataProbeService.artwork(session: remote, path: file.path,
                    size: file.size, cancellation: flag), !Task.isCancelled, !flag.cancelled {
                    ThumbnailCache.shared.save(result, for: key, modified: entry.modified)
                    logger.info("Artwork check completed: embedded PNG=\(result.png != nil)")
                }
            }
        } catch {
            // Log only the error domain/code, never a remote path or credentials.
            let error = error as NSError
            logger.info("Artwork remote check failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
        }
        await remote.disconnect()
    }

    static func refresh(force: Bool = false) {
        guard let url = TopShelfSnapshot.url else {
            logger.error("Shared Top Shelf container is unavailable")
            return
        }
        scheduleReads()
        let entries = PlaybackPositions.shared.watching().map {
            TopShelfEntry(id: $0.id, title: $0.file?.name ?? "Saved video · \($0.id.prefix(6))", artwork: publishedArtwork($0.file))
        }
        let previous = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([TopShelfEntry].self, from: $0)
        }
        if previous == entries {
            if force { TVTopShelfContentProvider.topShelfContentDidChange() }
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let retained = Set(entries.compactMap(\.artwork))
            for file in try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                where TopShelfSnapshot.artworkURL(file.lastPathComponent) != nil && !retained.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
            logger.info("Published Top Shelf snapshot with \(entries.count) items")
            TVTopShelfContentProvider.topShelfContentDidChange()
        } catch {
            let error = error as NSError
            logger.error("Top Shelf snapshot write failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
        }
    }
}
#endif
