import OSLog
import Foundation
import Combine
import AMSMB2

private let browserLog = Logger(subsystem: "com.example.BoraMin", category: "Browser")

@MainActor final class Browser: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var domain = UserDefaults.standard.string(forKey: "domain") ?? ""
    @Published var password = ""
    @Published var directShare = UserDefaults.standard.string(forKey: "share") ?? ""
    @Published var connected = false
    @Published private(set) var showingConnections = true
    var connectionID: String?
    @Published private(set) var connectionNeedsSetup = false
    @Published private(set) var connectionError: String?
    @Published private(set) var shares: [String] = []
    @Published var share = ""
    @Published var path = ""
    @Published var entries: [BrowserEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published var error: String?
    @Published var playing: PreparedMedia?
    let connections: ConnectionPreferences
    private let metadataCache: MediaMetadataCache
    private var session: RemoteSession?
    // Retained for existing SMB-only diagnostics; app operations use the neutral session.
    var client: SMB2Manager? {
        get { session?.smb }
        set { session = newValue.map { RemoteSession(smb: $0) } }
    }
    var isShareListing: Bool { URL(string: host)?.scheme == "smb" && share.isEmpty }
    var canDeleteFiles: Bool { session?.canDelete == true }
    var folderTitle: String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        if !share.isEmpty { return share }
        return connectionID.flatMap { connections.connection(id: $0)?.title } ?? URL(string: host)?.host ?? "Files"
    }
    func canDelete(_ file: PlaybackFile) -> Bool { URL(string: file.server)?.scheme == "smb" }
    private var metadataJobs: [UUID: CancellationFlag] = [:]
    var cancellation = CancellationFlag()
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    var playbackDirectory: URL?
    var activeStream: StreamingSession?
    static var cache: URL { FileManager.default.temporaryDirectory.appendingPathComponent("BoraMin", isDirectory: true) }

    private static let prepareCache: Void = {
        // Previous-process downloads are disposable; never persist passwords in UserDefaults.
        try? FileManager.default.removeItem(at: Browser.cache)
        try? FileManager.default.createDirectory(at: Browser.cache, withIntermediateDirectories: true)
    }()
    init(connections: ConnectionPreferences? = nil, metadataCache: MediaMetadataCache? = nil) {
        let connections = connections ?? ConnectionPreferences.shared
        self.connections = connections
        self.metadataCache = metadataCache ?? MediaMetadataCache.shared
        _ = Self.prepareCache
        connections.reload()
        if let saved = connections.selected {
            connectionID = saved.id; host = saved.server; username = saved.username
            domain = saved.domain; directShare = saved.share
        }
        password = connections.password(address: host, username: username, domain: domain) ?? ""
    }
    func reloadSelectedConnection() {
        guard !connected, !busy else { return }
        connections.reload()
        guard let id = connectionID, let saved = connections.connection(id: id) else { return }
        host = saved.server; username = saved.username; domain = saved.domain; directShare = saved.share
        password = connections.password(address: host, username: username, domain: domain) ?? ""
    }
    func openConnection(_ saved: SavedConnection) {
        guard !busy, playing == nil else { return }
        disconnect()
        connectionID = saved.id; host = saved.server; username = saved.username
        domain = saved.domain; directShare = saved.share
        password = connections.password(address: host, username: username, domain: domain) ?? ""
        connections.select(saved)
        showingConnections = false; connectionNeedsSetup = false; connectionError = nil; error = nil
        beginConnection(preservingLocation: false)
    }
    func showConnections() {
        guard !busy, playing == nil else { return }
        disconnect(); showingConnections = true; connectionNeedsSetup = false; connectionError = nil; error = nil
    }
    var hasSavedConnection: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // Reconnect only for the selected browser, on explicit retry/foreground or an SMB operation.
    func automaticallyConnect() async {
        guard !showingConnections, !connected, !busy, playing == nil else { return }
        reloadSelectedConnection()
        guard hasSavedConnection else { connectionNeedsSetup = true; return }
        beginConnection(preservingLocation: true)
        await operation?.value
    }
    private func beginConnection(preservingLocation: Bool) {
        // The model owns this task. A SwiftUI screen task disappearing must not cancel a user's connection request.
        perform("Connecting…", invalidateConnectionOnFailure: false) { [self] in
            do {
                try await ConnectionRetry.run { attempt in
                    if attempt > 1 { status = "Reconnecting…" }
                    try await establishConnection(preservingLocation: preservingLocation, attempt: attempt)
                }
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                connectionError = error.localizedDescription
                connectionNeedsSetup = Self.needsConnectionSetup(error)
                let failure = error as NSError
                browserLog.error("Connection failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
                throw error
            }
        }
    }
    private static func needsConnectionSetup(_ error: Error) -> Bool {
        if error is PlayerError { return true }
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain && [EACCES, EPERM, EINVAL, ENOENT].contains(Int32(error.code))
    }
    private func establishConnection(preservingLocation: Bool = false, attempt: Int = 1) async throws {
        let manager = try RemoteSession.make(server: host, username: username, domain: domain, password: password)
        // Build the new session before replacing a working one (including on failed edits).
        let targetShare = preservingLocation && !share.isEmpty ? share : directShare
        let targetPath = preservingLocation ? path : ""
        let newShares: [String]
        let newEntries: [BrowserEntry]
        let started = ProcessInfo.processInfo.systemUptime
        let phase = targetShare.isEmpty && manager.supportsShares ? "shares" : "directory"
        browserLog.notice("Connection opening phase=\(phase, privacy: .public) attempt=\(attempt)")
        do {
            if targetShare.isEmpty && manager.supportsShares {
                newShares = try await manager.listShares()
                newEntries = []
            } else {
                newShares = []
                newEntries = try await readDirectory(targetPath, shareName: targetShare, manager: manager)
            }
            try Task.checkCancellation()
        } catch {
            let failure = error as NSError
            browserLog.error("Connection attempt failed phase=\(phase, privacy: .public) attempt=\(attempt) domain=\(failure.domain, privacy: .public) code=\(failure.code) elapsed=\(ProcessInfo.processInfo.systemUptime - started)")
            await manager.disconnect(gracefully: false)
            throw error
        }
        browserLog.notice("Connection opened phase=\(phase, privacy: .public) attempt=\(attempt) elapsed=\(ProcessInfo.processInfo.systemUptime - started)")
        let old = session
        session = manager; shares = newShares; entries = newEntries
        share = targetShare; path = targetPath; connected = true
        showingConnections = false; connectionNeedsSetup = false; connectionError = nil
        Task { await old?.disconnect() }
    }
    func refreshConnection() {
        guard connected, !busy, playing == nil else { return }
        if isShareListing {
            perform("Reconnecting…") { [self] in
                guard let session else { return }
                let names = try await session.listShares()
                try Task.checkCancellation()
                shares = names
            }
        } else { openDirectory(path) }
    }
    func openShare(_ name: String) {
        perform("Opening \(name)…") { [self] in
            let contents = try await readDirectory("", shareName: name)
            try Task.checkCancellation()
            share = name; path = ""; entries = contents
        }
    }
    func openDirectory(_ target: String) {
        perform("Loading folder…") { [self] in
            let contents = try await readDirectory(target)
            try Task.checkCancellation()
            path = target; entries = contents
        }
    }
    func favoriteLocation(path: String) -> FavoriteLocation? {
        guard let session else { return nil }
        return FavoriteLocation(server: session.url, share: share, path: path, connectionID: connectionID)
    }
    func favoriteShare(_ name: String) -> FavoriteLocation? {
        guard let session else { return nil }
        return FavoriteLocation(server: session.url, share: name, path: "", connectionID: connectionID)
    }
    func openFavorite(_ favorite: FavoriteLocation, onOpen: @escaping @MainActor () -> Void) {
        perform("Opening favorite…") { [self] in
            connections.reload()
            guard let saved = connections.resolve(id: favorite.connectionID, server: favorite.server, share: favorite.share),
                  let url = URL(string: saved.server),
                  let manager = try? RemoteSession.make(server: url.absoluteString, username: saved.username, domain: saved.domain,
                    password: connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? "") else { throw PlayerError("This favorite’s connection is unavailable. Check Connections in Settings.") }
            let contents: [BrowserEntry]
            do {
                contents = try await readDirectory(favorite.path, shareName: favorite.share, manager: manager, connection: saved)
                try Task.checkCancellation()
            }
            catch { await manager.disconnect(); throw error }
            let old = session
            session = manager; host = saved.server; connectionID = saved.id
            username = saved.username; domain = saved.domain
            password = connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? ""
            directShare = saved.share; showingConnections = false
            share = favorite.share; path = favorite.path; entries = contents; connected = true
            onOpen()
            Task { await old?.disconnect() }
        }
    }
    func back() {
        if !path.isEmpty {
            let parent = (path as NSString).deletingLastPathComponent
            openDirectory(parent == "/" ? "" : parent)
        } else if session?.supportsShares == true && !share.isEmpty && directShare.isEmpty {
            perform("Loading shares…") { [self] in
                guard let session else { return }
                // Some SMB servers reject logoff even after a successful transfer.
                // Share enumeration opens its own connection, so teardown is best effort.
                await session.disconnect()
                let names = try await session.listShares(naturalOrder: false)
                try Task.checkCancellation()
                shares = names; share = ""; entries = []
            }
        } else { showConnections() }
    }
    func disconnect() {
        if busy { cancel() }
        metadataJobs.values.forEach { $0.cancel() }
        let old = session
        session = nil; connected = false; entries = []; shares = []; share = ""; path = ""
        password = connections.password(address: host, username: username, domain: domain) ?? ""
        Task { await old?.disconnect() }
    }
    private func ensureShareConnection(_ manager: RemoteSession, name: String) async throws {
        // AMSMB2 checks the session with SMB echo and reconnects expired/dropped sessions.
        do { try await manager.connectShare(name: name) }
        catch {
            try Task.checkCancellation()
            if manager === session, Self.needsConnectionSetup(error) {
                connected = false; connectionNeedsSetup = true
                connectionError = error.localizedDescription
            }
            throw error
        }
    }
    func readDirectory(_ target: String, shareName: String? = nil, manager: RemoteSession? = nil, connection: SavedConnection? = nil) async throws -> [BrowserEntry] {
        guard let session = manager ?? session else { throw PlayerError("Connect to a server first.") }
        let progress = PlaybackPositions.shared.allProgress()
        try await ensureShareConnection(session, name: shareName ?? share)
        try Task.checkCancellation()
        let contents = try await session.readDirectory(path: target)
        try Task.checkCancellation()
        return contents.map { original in
            var entry = original
            if !entry.directory {
                entry.progress = progress[PlaybackPositions.key(server: session.url,
                    share: shareName ?? share, path: entry.path, size: entry.size)]
                if entry.progress != nil, let file = PlaybackFile(server: session.url, share: shareName ?? share,
                    path: entry.path, size: entry.size, username: connection?.username ?? username, domain: connection?.domain ?? domain, connectionID: connection?.id ?? connectionID) {
                    PlaybackPositions.shared.remember(file)
                }
            }
            return entry
        }
    }
    func play(_ entry: BrowserEntry) {
        perform("Opening stream…") { [self] in
            let flag = cancellation
            guard let session else { throw PlayerError("Connection closed.") }
            try await ensureShareConnection(session, name: share)
            try Task.checkCancellation()
            let positionKey = Self.diagnosticPlaybackHistoryEnabled ?
                PlaybackPositions.key(server: session.url, share: share, path: entry.path, size: entry.size) : nil
            let media = try await PreparedMedia.stream(session: session, path: entry.path, size: entry.size,
                title: entry.name, directory: Self.cache, cancellation: flag, positionKey: positionKey)
            if flag.cancelled || Task.isCancelled { media.streaming?.stop(); throw CancellationError() }
            if let route = PlaybackRoute.expected(fileExtension: (entry.name as NSString).pathExtension, vp9: media.info.vp9 != 0) {
                let key = MediaMetadataCache.key(server: session.url, connectionID: connectionID, share: share, path: entry.path, size: entry.size)
                metadataCache.save(duration: media.info.duration, route: route, modified: entry.modified, for: key)
            }
            if let file = PlaybackFile(server: session.url, share: share, path: entry.path, size: entry.size,
                                       username: username, domain: domain, connectionID: connectionID) { PlaybackPositions.shared.remember(file) }
            activeStream = media.streaming; playing = media
        }
    }
    func recoverWatchingMetadata(at location: FavoriteLocation) async {
        guard !Task.isCancelled,
              let saved = connections.resolve(id: location.connectionID, server: location.server, share: location.share),
              let url = URL(string: saved.server),
              let manager = try? RemoteSession.make(server: url.absoluteString, username: saved.username, domain: saved.domain,
                    password: connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? "", timeout: 5) else { return }
        _ = try? await readDirectory(location.path, shareName: location.share, manager: manager, connection: saved)
        await manager.disconnect()
    }
    func openWatching(_ file: PlaybackFile) {
        perform("Opening stream…") { [self] in
            let flag = cancellation
            connections.reload()
            guard let saved = connections.resolve(id: file.connectionID, server: file.server,
                    username: file.username, domain: file.domain, share: file.share),
                  let url = URL(string: saved.server),
                  let manager = try? RemoteSession.make(server: url.absoluteString, username: saved.username, domain: saved.domain,
                    password: connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? "") else { throw PlayerError("This video’s connection is unavailable. Check Connections in Settings.") }
            var adopted = false
            defer { if !adopted { manager.abort() } }
            try await manager.connectShare(name: file.share)
            let attributes = try await manager.attributes(path: file.path)
            try Task.checkCancellation()
            guard attributes.size == file.size else {
                throw PlayerError("This file has changed. Open it again from Connections.")
            }
            let media = try await PreparedMedia.stream(session: manager, path: file.path, size: file.size,
                title: file.name, directory: Self.cache, cancellation: flag, positionKey: Self.diagnosticPlaybackHistoryEnabled ? file.key : nil)
            if flag.cancelled || Task.isCancelled { media.streaming?.stop(); throw CancellationError() }
            if let route = PlaybackRoute.expected(fileExtension: (file.path as NSString).pathExtension, vp9: media.info.vp9 != 0) {
                let key = MediaMetadataCache.key(server: URL(string: file.server)!, connectionID: file.connectionID, share: file.share, path: file.path, size: file.size)
                let modified = attributes.modified
                metadataCache.save(duration: media.info.duration, route: route, modified: modified, for: key)
            }
            let old = session
            session = manager; activeStream = media.streaming; playing = media
            adopted = true
            connectionID = saved.id; host = saved.server; username = saved.username; domain = saved.domain
            password = connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? ""
            Task { await old?.disconnect() }
        }
    }

    func cancel() {
        metadataJobs.values.forEach { $0.cancel() }
        guard busy else { return }
        cancellation.cancel()
        operation?.cancel()
        operationID = nil; operation = nil
        busy = false; status = ""; error = nil
        // Do not reuse a session whose outstanding callbacks may still be unwinding.
        // The next connection attempt creates a fresh manager, preserving the current location.
        let old = session
        session = old.flatMap { $0.replacement() }
        if session == nil { connected = false }
        if let old { old.abort() }
    }
    func playbackEnded() {
        activeStream?.stop(); activeStream = nil
        playing = nil
        refreshProgress()
        if let directory = playbackDirectory { try? FileManager.default.removeItem(at: directory) }
        playbackDirectory = nil
        Self.reportDiagnosticPlaybackEnded()
    }
    func metadataTaskID(_ entry: BrowserEntry) -> String {
        [connectionID ?? "", host, share, entry.id, String(entry.size), String(entry.modified), busy || playing != nil ? "suspended" : "visible"].joined(separator: "\0")
    }
    func loadMetadata(_ entry: BrowserEntry) async {
        guard !busy, playing == nil, !entry.directory, entry.playable, entry.playbackRoute == nil, let session, connected else { return }
        let currentShare = share
        let key = MediaMetadataCache.key(server: session.url, connectionID: connectionID, share: share, path: entry.path, size: entry.size)
        var record = metadataCache.value(for: key, modified: entry.modified)
        if record == nil {
            let flag = CancellationFlag()
            let job = UUID()
            metadataJobs[job] = flag
            defer { metadataJobs.removeValue(forKey: job) }
            let result = await MetadataProbeService.inspect(session: session, path: entry.path, size: entry.size,
                fileExtension: (entry.name as NSString).pathExtension, cancellation: flag)
            guard !Task.isCancelled, !flag.cancelled, let route = result.1 else { return }
            metadataCache.save(duration: result.0, route: route, modified: entry.modified, for: key)
            record = metadataCache.value(for: key, modified: entry.modified)
        }
        guard !Task.isCancelled, let record, self.session === session, share == currentShare,
              let index = entries.firstIndex(where: { $0.id == entry.id && $0.size == entry.size && $0.modified == entry.modified }) else { return }
        entries[index].duration = record.duration
        entries[index].playbackRoute = record.route
    }
    func loadWatchingMetadata(_ file: PlaybackFile) async {
        guard !busy, playing == nil else { return }
        let key = MediaMetadataCache.key(server: URL(string: file.server)!, connectionID: file.connectionID, share: file.share, path: file.path, size: file.size)
        guard metadataCache.value(for: key) == nil,
              PlaybackRoute.expected(fileExtension: (file.name as NSString).pathExtension, vp9: nil) == nil,
              let saved = connections.resolve(id: file.connectionID, server: file.server, username: file.username, domain: file.domain, share: file.share),
              let url = URL(string: saved.server),
              let manager = try? RemoteSession.make(server: url.absoluteString, username: saved.username, domain: saved.domain,
                    password: connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? "", timeout: 5) else { return }
        let flag = CancellationFlag(), job = UUID()
        metadataJobs[job] = flag
        defer { metadataJobs.removeValue(forKey: job) }
        let result = await MetadataProbeService.inspect(session: manager, path: file.path, size: file.size,
            fileExtension: (file.name as NSString).pathExtension, shareToConnect: file.share, cancellation: flag)
        guard !Task.isCancelled, !flag.cancelled, let route = result.1 else { return }
        metadataCache.save(duration: result.0, route: route, modified: 0, for: key)
    }
    func deleteFile(_ entry: BrowserEntry) {
        guard !busy, playing == nil, !entry.directory, let session, session.canDelete,
              entries.contains(where: { $0.path == entry.path && !$0.directory }) else { return }
        perform("Deleting file…", invalidateConnectionOnFailure: false) { [self] in
            try await session.removeFile(path: entry.path)
            try Task.checkCancellation()
            PlaybackPositions.shared.clear(PlaybackPositions.key(server: session.url, share: share, path: entry.path, size: entry.size))
            entries.removeAll { $0.path == entry.path }
        }
    }
    func deleteWatchingFile(_ file: PlaybackFile, onDelete: @escaping () -> Void) {
        guard !busy, playing == nil, canDelete(file) else { return }
        perform("Deleting file…", invalidateConnectionOnFailure: false) { [self] in
            connections.reload()
            guard let saved = connections.resolve(id: file.connectionID, server: file.server,
                    username: file.username, domain: file.domain, share: file.share),
                  let url = URL(string: saved.server),
                  let manager = try? RemoteSession.make(server: url.absoluteString, username: saved.username, domain: saved.domain,
                    password: connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? "") else { throw PlayerError("This video’s connection is unavailable. Check Connections in Settings.") }
            defer { Task { await manager.disconnect() } }
            try await manager.connectShare(name: file.share)
            let attributes = try await manager.attributes(path: file.path)
            try Task.checkCancellation()
            guard !attributes.directory,
                  attributes.size == file.size else {
                throw PlayerError("This file has changed. Open its folder in Connections before deleting it.")
            }
            try await manager.removeFile(path: file.path)
            try Task.checkCancellation()
            PlaybackPositions.shared.clear(file.key)
            onDelete()
            NotificationCenter.default.post(name: Notification.Name("BoraMinPlaybackSync"), object: nil)
        }
    }
    func resetPlayback(_ entry: BrowserEntry) {
        guard !busy, playing == nil, entry.playable, let session else { return }
        let key = PlaybackPositions.key(server: session.url, share: share, path: entry.path, size: entry.size)
        PlaybackPositions.shared.clear(key)
        refreshProgress()
    }
    func refreshProgress() {
        if let session {
            let progress = PlaybackPositions.shared.allProgress()
            entries = entries.map { entry in
                var updated = entry
                if !entry.directory {
                    updated.progress = progress[PlaybackPositions.key(server: session.url,
                        share: share, path: entry.path, size: entry.size)]
                }
                return updated
            }
        }
    }
    func perform(_ message: String, invalidateConnectionOnFailure: Bool = true, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        metadataJobs.values.forEach { $0.cancel() }
        let flag = CancellationFlag(); cancellation = flag
        let id = UUID(); operationID = id
        busy = true; status = message; error = nil
        operation = Task {
            defer {
                if operationID == id { busy = false; status = ""; operation = nil; operationID = nil }
            }
            do {
                try Task.checkCancellation()
                try await withTaskCancellationHandler {
                    try await action()
                } onCancel: { flag.cancel() }
            }
            catch is CancellationError { }
            catch {
                guard operationID == id, !Task.isCancelled, !flag.cancelled else { return }
                browserLog.error("BORAMIN_ERROR \(error.localizedDescription)")
                let failure = error as NSError
                browserLog.error("Operation failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
                Self.reportDiagnosticFailure(failure)
                let transportCodes: [Int32] = [ENOTCONN, ECONNRESET, ECONNABORTED, ENETRESET, ENOLINK,
                                               EPIPE, ETIMEDOUT, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ECONNREFUSED]
                if invalidateConnectionOnFailure, failure.domain == NSPOSIXErrorDomain, transportCodes.contains(Int32(failure.code)) {
                    connected = false
                    connectionError = error.localizedDescription
                }
                self.error = error.localizedDescription
            }
        }
    }
}
