import OSLog
import SwiftUI
import AMSMB2

private let browserLog = Logger(subsystem: "com.example.BoraMin", category: "Browser")

struct BrowserEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let directory: Bool
    let size: Int64
    var modified: Double = 0
    var duration: Double? = nil
    var progress: PlaybackProgress? = nil
    var displayName: String { progress.map { "\($0.prefix) \(name)" } ?? name }
    var durationText: String? {
        guard let value = duration ?? progress?.duration, value.isFinite, value > 0, value < Double(Int.max) else { return nil }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var sizeAndDuration: String {
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return durationText.map { "\($0) · \(sizeText)" } ?? sizeText
    }
    var playable: Bool { ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts"].contains((name as NSString).pathExtension.lowercased()) }
}

@MainActor final class Browser: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var domain = UserDefaults.standard.string(forKey: "domain") ?? ""
    @Published var password = ""
    @Published var directShare = UserDefaults.standard.string(forKey: "share") ?? ""
    @Published private(set) var connected = false
    @Published private(set) var connectionNeedsSetup = false
    @Published private(set) var connectionError: String?
    @Published private(set) var shares: [String] = []
    @Published private(set) var share = ""
    @Published private(set) var path = ""
    @Published private(set) var entries: [BrowserEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published var error: String?
    @Published var playing: PreparedMedia?
    private var client: SMB2Manager?
    private var metadataJobs: [UUID: CancellationFlag] = [:]
    private var cancellation = CancellationFlag()
    private var operation: Task<Void, Never>?
    private var playbackDirectory: URL?
    private var activeStream: StreamingSession?
    private var loadedConnection: [String:String] = [:]
    private var connectionDraft: [String:String] {
        ["server":host,"username":username,"domain":domain,"share":directShare,"password":password]
    }
    static var cache: URL { FileManager.default.temporaryDirectory.appendingPathComponent("BoraMin", isDirectory: true) }

    private static let prepareCache: Void = {
        // Previous-process downloads are disposable; never persist passwords in UserDefaults.
        try? FileManager.default.removeItem(at: Browser.cache)
        try? FileManager.default.createDirectory(at: Browser.cache, withIntermediateDirectories: true)
    }()
    init() {
        _ = Self.prepareCache
        password = ConnectionPreferences.shared.password(address: host, username: username, domain: domain) ?? ""
        loadedConnection=connectionDraft
    }
    func reloadSavedConnectionIfUnchanged() {
        guard !connected, !busy, connectionDraft == loadedConnection else { return }
        host=UserDefaults.standard.string(forKey:"server") ?? ""
        username=UserDefaults.standard.string(forKey:"username") ?? ""
        domain=UserDefaults.standard.string(forKey:"domain") ?? ""
        directShare=UserDefaults.standard.string(forKey:"share") ?? ""
        password=ConnectionPreferences.shared.password(address:host,username:username,domain:domain) ?? ""
        if loadedConnection != connectionDraft {
            connectionNeedsSetup = false
            share = ""; path = ""
        }
        loadedConnection=connectionDraft
    }
    func useCredentials(from browser: Browser) {
        host = browser.host
        username = browser.username
        domain = browser.domain
        password = browser.password
    }
    var hasSavedConnection: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func connect(host: String, username: String, domain: String, password: String, directShare: String,
                 onConnect: @escaping @MainActor () -> Void) {
        perform("Connecting…", invalidateConnectionOnFailure: false) { [self] in
            let previous = connectionDraft
            self.host = host; self.username = username; self.domain = domain
            self.password = password; self.directShare = directShare
            do {
                try await establishConnection()
                onConnect()
            } catch {
                self.host = previous["server"] ?? ""; self.username = previous["username"] ?? ""
                self.domain = previous["domain"] ?? ""; self.password = previous["password"] ?? ""
                self.directShare = previous["share"] ?? ""
                connectionError = error.localizedDescription
                if !connected { connectionNeedsSetup = true }
                throw error
            }
        }
    }
    // Called while Files is visible. Network outages retry without repeatedly opening setup.
    func automaticallyConnect(usingSavedConnection: Bool = true) async {
        guard !connected, !busy, playing == nil else { return }
        if usingSavedConnection { reloadSavedConnectionIfUnchanged() }
        guard hasSavedConnection else { connectionNeedsSetup = true; return }
        guard !connectionNeedsSetup else { return }
        busy = true; status = "Connecting…"
        defer { busy = false; status = "" }
        do { try await establishConnection(preservingLocation: true, saveConnection: usingSavedConnection) }
        catch is CancellationError { }
        catch {
            connectionError = error.localizedDescription
            connectionNeedsSetup = Self.needsConnectionSetup(error)
        }
    }
    private static func needsConnectionSetup(_ error: Error) -> Bool {
        if error is PlayerError { return true }
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain && [EACCES, EPERM, EINVAL, ENOENT].contains(Int32(error.code))
    }
    private func establishConnection(preservingLocation: Bool = false, saveConnection: Bool = true) async throws {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw.contains("://") ? raw : "smb://\(raw)"),
              url.scheme == "smb", let hostname = url.host, !hostname.isEmpty,
              url.user == nil, url.password == nil, url.path.isEmpty || url.path == "/" else {
            throw PlayerError("Enter a server name or IP address, such as smb://nas.local. Enter the share separately.")
        }
        let credential = URLCredential(user: username.isEmpty ? "guest" : username, password: password, persistence: .none)
        guard let manager = SMB2Manager(url: url, domain: domain, credential: credential) else { throw PlayerError("Invalid SMB server.") }
        manager.timeout = 20
        // Build the new session before replacing a working one (including on failed edits).
        let targetShare = preservingLocation && !share.isEmpty ? share : directShare
        let targetPath = preservingLocation ? path : ""
        let newShares: [String]
        let newEntries: [BrowserEntry]
        if targetShare.isEmpty {
            newShares = try await manager.listShares().map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            newEntries = []
        } else {
            newShares = []
            newEntries = try await readDirectory(targetPath, shareName: targetShare, manager: manager)
        }
        try Task.checkCancellation()
        if saveConnection {
            try ConnectionPreferences.shared.save(server: url, username: username, domain: domain,
                                                  share: directShare, password: password)
        }
        let old = client
        client = manager; shares = newShares; entries = newEntries
        share = targetShare; path = targetPath; connected = true
        connectionNeedsSetup = false; connectionError = nil
        loadedConnection = connectionDraft
        Task { try? await old?.disconnectShare(gracefully: true) }
    }
    func refreshConnection() {
        guard connected, !busy, playing == nil else { return }
        if share.isEmpty {
            perform("Reconnecting…") { [self] in
                guard let client else { return }
                shares = try await client.listShares().map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        } else { openDirectory(path) }
    }
    func runSmokeTestIfRequested() {
        if let index = CommandLine.arguments.firstIndex(of: "--stream-smoke-test"), CommandLine.arguments.count > index + 2 {
            let testShare = CommandLine.arguments[index + 1], testPath = CommandLine.arguments[index + 2]
            perform("Opening test share…") { [self] in
                let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: raw.contains("://") ? raw : "smb://\(raw)"),
                      let manager = SMB2Manager(url: url, domain: domain, credential: URLCredential(user: username.isEmpty ? "guest" : username, password: password, persistence: .none)) else { throw PlayerError("Invalid test server.") }
                manager.timeout = 15; client = manager
                try await manager.connectShare(name: testShare)
                let attributes = try await manager.attributesOfItem(atPath: testPath)
                let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                let entry = BrowserEntry(name: (testPath as NSString).lastPathComponent, path: testPath, directory: false, size: size)
                connected = true; share = testShare; path = (testPath as NSString).deletingLastPathComponent
                entries = try await readDirectory(path)
                Task { @MainActor in
                    if CommandLine.arguments.contains("--exercise-player-lifecycle") {
                        await self.exercisePlayerLifecycle(entry)
                    } else { self.play(entry) }
                }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--smb-smoke-test"), CommandLine.arguments.count > index + 1 {
            let address = CommandLine.arguments[index + 1]
            perform("Connecting to isolated SMB test share…") { [self] in
                guard let url = URL(string: address), let manager = SMB2Manager(url: url, credential: URLCredential(user: "guest", password: "", persistence: .none)) else { throw PlayerError("Invalid test server.") }
                manager.timeout = 15; client = manager
                let names = try await manager.listShares().map(\.name)
                guard names.contains("TESTMEDIA") else { throw PlayerError("Test share not enumerated.") }
                print("BORAMIN_SMB shares enumerated: \(names.count)")
                try await manager.connectShare(name: "TESTMEDIA")
                let root = try await readDirectory("")
                guard root.contains(where: { $0.directory && $0.name == "Nested" }) else { throw PlayerError("Test folder missing.") }
                let files = try await readDirectory("Nested")
                guard let entry = files.first(where: { $0.playable }) else { throw PlayerError("Test video missing.") }
                print("BORAMIN_SMB browsed nested folder; video size \(entry.size)")
                connected = true; share = "TESTMEDIA"; path = "Nested"; entries = files
                Task { @MainActor in self.play(entry) }
            }
            return
        }
        let nativeTracks = CommandLine.arguments.contains("--native-tracks-smoke-test")
        guard nativeTracks || CommandLine.arguments.contains("--smoke-test") else { return }
        perform("Preparing device smoke test…") { [self] in
            let source = nativeTracks ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("native-tracks.mp4") :
                Bundle.main.url(forResource: "smoke", withExtension: "webm") ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("smoke.webm")
            let directory = Self.cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let flag = cancellation
            let media = try await Task.detached {
                try PreparedMedia.prepare(source: source, directory: directory, title: "Media playback smoke test", cancellation: flag)
            }.value
            playbackDirectory = directory; playing = media
        }
    }
    func openShare(_ name: String) {
        perform("Opening \(name)…") { [self] in
            let contents = try await readDirectory("", shareName: name)
            share = name; path = ""; entries = contents
        }
    }
    func openDirectory(_ target: String) {
        perform("Loading folder…") { [self] in
            let contents = try await readDirectory(target)
            path = target; entries = contents
        }
    }
    func favoriteLocation(path: String) -> FavoriteLocation? {
        guard let client else { return nil }
        return FavoriteLocation(server: client.url, share: share, path: path)
    }
    func favoriteShare(_ name: String) -> FavoriteLocation? {
        guard let client else { return nil }
        return FavoriteLocation(server: client.url, share: name, path: "")
    }
    func openFavorite(_ favorite: FavoriteLocation, onOpen: @escaping @MainActor () -> Void) {
        perform("Opening favorite…") { [self] in
            guard let url = URL(string: favorite.server),
                  let manager = SMB2Manager(url: url, domain: domain, credential: URLCredential(
                    user: username.isEmpty ? "guest" : username,
                    password: ConnectionPreferences.shared.password(address: favorite.server, username: username, domain: domain) ?? password,
                    persistence: .none)) else { throw PlayerError("Invalid favorite server.") }
            manager.timeout = 20
            let contents = try await readDirectory(favorite.path, shareName: favorite.share, manager: manager)
            let old = client
            client = manager; host = favorite.server
            share = favorite.share; path = favorite.path; entries = contents; connected = true
            onOpen()
            Task { try? await old?.disconnectShare(gracefully: true) }
        }
    }
    func back() {
        if !path.isEmpty {
            let parent = (path as NSString).deletingLastPathComponent
            openDirectory(parent == "/" ? "" : parent)
        } else if !share.isEmpty && directShare.isEmpty {
            perform("Loading shares…") { [self] in
                guard let client else { return }
                // Some SMB servers reject logoff even after a successful transfer.
                // Share enumeration opens its own connection, so teardown is best effort.
                try? await client.disconnectShare(gracefully: true)
                shares = try await client.listShares().map(\.name).sorted()
                share = ""; entries = []
            }
        } else { disconnect() }
    }
    func disconnect() {
        metadataJobs.values.forEach { $0.cancel() }
        let old = client
        client = nil; connected = false; entries = []; shares = []; share = ""; path = ""
        password = ConnectionPreferences.shared.password(address: host, username: username, domain: domain) ?? ""
        Task { try? await old?.disconnectShare(gracefully: true) }
    }
    private func ensureShareConnection(_ manager: SMB2Manager, name: String) async throws {
        // AMSMB2 checks the session with SMB echo and reconnects expired/dropped sessions.
        do { try await manager.connectShare(name: name) }
        catch {
            if manager === client, Self.needsConnectionSetup(error) {
                connected = false; connectionNeedsSetup = true
                connectionError = error.localizedDescription
            }
            throw error
        }
    }
    private func readDirectory(_ target: String, shareName: String? = nil, manager: SMB2Manager? = nil) async throws -> [BrowserEntry] {
        guard let client = manager ?? client else { throw PlayerError("Connect to a server first.") }
        let progress = PlaybackPositions.shared.allProgress()
        try await ensureShareConnection(client, name: shareName ?? share)
        return try await client.contentsOfDirectory(atPath: target).compactMap { attributes in
            guard let name = attributes[.nameKey] as? String, !name.hasPrefix(".") else { return nil }
            var entry = BrowserEntry(name: name, path: target.isEmpty ? name : "\(target)/\(name)",
                directory: attributes[.fileResourceTypeKey] as? URLFileResourceType == .directory,
                size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
            entry.modified = (attributes[.contentModificationDateKey] as? Date)?.timeIntervalSince1970 ?? 0
            if !entry.directory {
                entry.progress = progress[PlaybackPositions.key(server: client.url,
                    share: shareName ?? share, path: entry.path, size: entry.size)]
                if entry.progress != nil, let file = PlaybackFile(server: client.url, share: shareName ?? share,
                    path: entry.path, size: entry.size, username: username, domain: domain) {
                    PlaybackPositions.shared.remember(file)
                }
            }
            return entry
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func play(_ entry: BrowserEntry) {
        let flag = CancellationFlag(); cancellation = flag
        perform("Opening stream…") { [self] in
            guard let client else { throw PlayerError("SMB connection closed.") }
            try await ensureShareConnection(client, name: share)
            let positionKey = CommandLine.arguments.contains("--no-playback-history") ? nil :
                PlaybackPositions.key(server: client.url, share: share, path: entry.path, size: entry.size)
            let media = try await PreparedMedia.stream(client: client, path: entry.path, size: entry.size,
                title: entry.name, directory: Self.cache, cancellation: flag, positionKey: positionKey)
            if flag.cancelled { media.streaming?.stop(); throw CancellationError() }
            if let file = PlaybackFile(server: client.url, share: share, path: entry.path, size: entry.size,
                                       username: username, domain: domain) { PlaybackPositions.shared.remember(file) }
            activeStream = media.streaming; playing = media
        }
    }
    func recoverWatchingMetadata(at location: FavoriteLocation) async {
        guard !Task.isCancelled, let url = URL(string: location.server),
              let manager = SMB2Manager(url: url, domain: domain, credential: URLCredential(
                user: username.isEmpty ? "guest" : username,
                password: ConnectionPreferences.shared.password(address: location.server, username: username, domain: domain) ?? password,
                persistence: .none)) else { return }
        manager.timeout = 5
        // A shallow read of an already saved folder can identify legacy hashed bookmarks.
        // Unavailable favorites are skipped; this never changes the Files navigation state.
        _ = try? await readDirectory(location.path, shareName: location.share, manager: manager)
        try? await manager.disconnectShare(gracefully: true)
    }
    func openWatching(_ file: PlaybackFile) {
        let flag = CancellationFlag(); cancellation = flag
        perform("Opening stream…") { [self] in
            guard let url = URL(string: file.server),
                  let manager = SMB2Manager(url: url, domain: file.domain, credential: URLCredential(
                    user: file.username.isEmpty ? "guest" : file.username,
                    password: ConnectionPreferences.shared.password(address: file.server, username: file.username, domain: file.domain) ?? "",
                    persistence: .none)) else { throw PlayerError("Invalid saved video location.") }
            manager.timeout = 20
            try await manager.connectShare(name: file.share)
            let attributes = try await manager.attributesOfItem(atPath: file.path)
            guard (attributes[.fileSizeKey] as? NSNumber)?.int64Value == file.size else {
                throw PlayerError("This file has changed. Open it again from Files.")
            }
            let media = try await PreparedMedia.stream(client: manager, path: file.path, size: file.size,
                title: file.name, directory: Self.cache, cancellation: flag, positionKey: CommandLine.arguments.contains("--no-playback-history") ? nil : file.key)
            if flag.cancelled { media.streaming?.stop(); throw CancellationError() }
            let old = client
            client = manager; activeStream = media.streaming; playing = media
            Task { try? await old?.disconnectShare(gracefully: true) }
        }
    }

    private func exercisePlayerLifecycle(_ entry: BrowserEntry) async {
        var frames = Set<UUID>()
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("BoraMinProbeFrame"), object: nil, queue: .main) { note in
            if let id = note.object as? UUID { frames.insert(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            for cycle in 1...3 {
                try Task.checkCancellation()
                var next = entry
                if cycle == 2, let index = CommandLine.arguments.firstIndex(of: "--test-second-video"), CommandLine.arguments.count > index + 1, let client {
                    let path = CommandLine.arguments[index + 1]
                    let attributes = try await client.attributesOfItem(atPath: path)
                    next = BrowserEntry(name: (path as NSString).lastPathComponent, path: path, directory: false,
                                        size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
                }
                play(next)
                for _ in 0..<300 {
                    if playing != nil || error != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let media = playing else { throw PlayerError(error ?? "Lifecycle test could not open video.") }
                print("BORAMIN_LIFECYCLE opened cycle=\(cycle) id=\(media.id)")
                if CommandLine.arguments.contains("--probe-frames-only") {
                    for _ in 0..<600 {
                        if frames.contains(media.id) || error != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard frames.contains(media.id) else { throw PlayerError("No confirmed video in lifecycle cycle \(cycle).") }
                    try await Task.sleep(for: .seconds(3))
                } else { try await Task.sleep(for: .seconds(10)) }
                guard playing?.id == media.id else { throw PlayerError("Playback was dismissed during the lifecycle test.") }
                playing = nil
                for _ in 0..<100 {
                    if activeStream == nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard activeStream == nil else { throw PlayerError("Previous player did not dismiss.") }
                if let key = media.positionKey {
                    guard let progress = PlaybackPositions.shared.progress(for: key),
                          entries.first(where: { $0.path == entry.path })?.displayName.hasPrefix("(") == true else {
                        throw PlayerError("Playback position or file-list prefix was not saved.")
                    }
                    print("BORAMIN_LIFECYCLE bookmark cycle=\(cycle) prefix=\(progress.prefix)")
                }
                print("BORAMIN_LIFECYCLE dismissed cycle=\(cycle)")
                try await Task.sleep(for: .milliseconds(500))
            }
            print("BORAMIN_LIFECYCLE PASS: three open/play/dismiss cycles in one process")
        } catch { print("BORAMIN_LIFECYCLE FAILED: \(error.localizedDescription)") }
    }

    func cancel() { cancellation.cancel(); status = "Cancelling…" }
    func playbackEnded() {
        activeStream?.stop(); activeStream = nil
        playing = nil
        refreshProgress()
        if let directory = playbackDirectory { try? FileManager.default.removeItem(at: directory) }
        playbackDirectory = nil
        if CommandLine.arguments.contains("--exercise-mkv-controls") { print("BORAMIN_MKV_TEST returned to browser") }
    }
    private static let metadataQueue = DispatchQueue(label: "BoraMin.durationProbe", qos: .utility)
    func loadDuration(_ entry: BrowserEntry) async {
        guard !entry.directory, entry.playable, entry.duration == nil, let client, connected else { return }
        let currentShare = share
        let key = PlaybackPositions.key(server: client.url, share: share, path: entry.path, size: entry.size)
        let cacheKey = "mediaDuration." + key + "." + String(entry.modified)
        var duration = UserDefaults.standard.double(forKey: cacheKey)
        if duration <= 0 {
            let flag = CancellationFlag()
            let job = UUID()
            metadataJobs[job] = flag
            defer { metadataJobs.removeValue(forKey: job) }
            duration = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    Self.metadataQueue.async {
                        guard !flag.cancelled else { continuation.resume(returning: 0); return }
                        let source = SMBRemoteFile(client: client, path: entry.path, size: entry.size, cancellation: flag)
                        var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
                        guard let reader = media_open_io(source.makeIO(), &info, &error, error.count) else { continuation.resume(returning: 0); return }
                        media_close(reader)
                        continuation.resume(returning: info.duration)
                    }
                }
            } onCancel: { flag.cancel() }
        }
        guard !Task.isCancelled, duration.isFinite, duration > 0 else { return }
        UserDefaults.standard.set(duration, forKey: cacheKey)
        guard self.client === client, share == currentShare,
              let index = entries.firstIndex(where: { $0.id == entry.id && $0.size == entry.size }) else { return }
        entries[index].duration = duration
    }
    func deleteFile(_ entry: BrowserEntry) {
        guard !busy, playing == nil, !entry.directory, let client,
              entries.contains(where: { $0.path == entry.path && !$0.directory }) else { return }
        perform("Deleting file…", invalidateConnectionOnFailure: false) { [self] in
            try await client.removeFile(atPath: entry.path)
            PlaybackPositions.shared.clear(PlaybackPositions.key(server: client.url, share: share, path: entry.path, size: entry.size))
            entries.removeAll { $0.path == entry.path }
        }
    }
    func resetPlayback(_ entry: BrowserEntry) {
        guard !busy, playing == nil, entry.playable, let client else { return }
        let key = PlaybackPositions.key(server: client.url, share: share, path: entry.path, size: entry.size)
        PlaybackPositions.shared.clear(key)
        refreshProgress()
    }
    func refreshProgress() {
        if let client {
            let progress = PlaybackPositions.shared.allProgress()
            entries = entries.map { entry in
                var updated = entry
                if !entry.directory {
                    updated.progress = progress[PlaybackPositions.key(server: client.url,
                        share: share, path: entry.path, size: entry.size)]
                }
                return updated
            }
        }
    }
    private func perform(_ message: String, invalidateConnectionOnFailure: Bool = true, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        metadataJobs.values.forEach { $0.cancel() }
        if cancellation.cancelled { cancellation = CancellationFlag() }
        busy = true; status = message; error = nil
        operation = Task {
            defer { busy = false; status = ""; operation = nil }
            do { try await action() }
            catch is CancellationError { }
            catch {
                browserLog.error("BORAMIN_ERROR \(error.localizedDescription)")
                let failure = error as NSError
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

#if os(tvOS) || os(iOS)
struct BrowserScreen: View {
    private enum Destination: Hashable { case files, favorites, favoriteFiles(FavoriteLocation), watching, settings, connectionSetup }
    @StateObject private var filesBrowser = Browser()
    @StateObject private var favoriteBrowser = Browser()
    @StateObject private var watchingBrowser = Browser()
    @State private var watching = PlaybackPositions.shared.watching()
    @StateObject private var favorites = Favorites()
    @StateObject private var cloud = ICloudSync.shared
    @State private var navigation: [Destination] = []
    @State private var fileToDelete: BrowserEntry?
    @AppStorage("displayAllFiles") private var displayAllFiles = false
    @AppStorage("showDebugInfo") private var showDebugInfo = false
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var listingFocus
    @FocusState private var focusedHome: Destination?
    private var browser: Browser {
        switch navigation.last {
        case .favorites, .favoriteFiles: return favoriteBrowser
        case .watching: return watchingBrowser
        default: return filesBrowser
        }
    }
    private var visibleEntries: [BrowserEntry] {
        browser.entries.filter { displayAllFiles || $0.directory || $0.playable }
    }
    private var firstFocusableEntry: String? {
        visibleEntries.first { $0.directory || $0.playable }?.id
    }
    private var atFavoriteRoot: Bool {
        guard case .favoriteFiles(let favorite) = navigation.last else { return false }
        return browser.share == favorite.share && browser.path == favorite.path
    }
    private var title: String {
        switch navigation.last {
        case .files, .favoriteFiles:
            return browser.share.isEmpty ? "Files" : "\(browser.share)\(browser.path.isEmpty ? "" : " / \(browser.path)")"
        case .favorites: return "Favorites"
        case .watching: return "Watching"
        case .settings: return "Settings"
        case .connectionSetup: return "Connection Setup"
        case nil: return "BoraMin"
        }
    }
    var body: some View {
        NavigationStack(path: $navigation) {
            home
                .navigationDestination(for: Destination.self) { destination in
                    Group {
                        switch destination {
                        case .files, .favoriteFiles: files
                        case .favorites: favoritesList
                        case .watching: watchingList
                        case .settings: settings
                        case .connectionSetup: connection
                        }
                    }
                    .navigationTitle(title)
                }
                #if os(tvOS)
                .navigationTitle("")
                #else
                .navigationTitle("BoraMin")
                #endif
        }
        .background(Color.black.ignoresSafeArea())
        .disabled(browser.busy)
        .task {
            cloud.activate()
            filesBrowser.runSmokeTestIfRequested()
            if CommandLine.arguments.contains("--icloud-sync-check") {
                await cloud.runPreferenceCheckIfRequested()
                await cloud.synchronize()
                UserDefaults.standard.set(cloud.diagnosticSummary(),forKey:"cloudDiagnosticSummary")
                print("BORAMIN_ICLOUD_CHECK \(cloud.status) pending=\(cloud.pendingCount)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:ICloudSync.dataChanged)) { _ in
            favorites.reload()
            watching = PlaybackPositions.shared.watching()
            filesBrowser.reloadSavedConnectionIfUnchanged()
            favoriteBrowser.reloadSavedConnectionIfUnchanged()
            filesBrowser.refreshProgress()
            favoriteBrowser.refreshProgress()
        }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
                .receive(on: RunLoop.main)) { _ in
                    watching = PlaybackPositions.shared.watching()
                    filesBrowser.refreshProgress()
                    favoriteBrowser.refreshProgress()
                }
            .overlay {
                if browser.busy {
                    VStack(spacing: 24) {
                        ProgressView()
                        Text(browser.status).multilineTextAlignment(.center)
                        if browser.status.hasPrefix("Opening stream") || browser.status.hasPrefix("Preparing") {
                            Button("Cancel") { browser.cancel() }
                        }
                    }.padding(50).background(Color.black, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .alert("Unable to continue", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
                Button("OK") { browser.error = nil }
            } message: { Text(browser.error ?? "") }
            .alert("Delete File?", isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } }), presenting: fileToDelete) { entry in
                Button("Delete", role: .destructive) { browser.deleteFile(entry); fileToDelete = nil }
                Button("Cancel", role: .cancel) { fileToDelete = nil }
            } message: { entry in Text("Permanently delete \(entry.name) from the server? This cannot be undone.") }
            .fullScreenCover(item: Binding(get: { browser.playing }, set: { browser.playing = $0 }), onDismiss: { browser.playbackEnded() }) { media in
                NativePlayer(media: media) { message in
                    browser.playing = nil
                    // Present the error after the system player dismisses.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500)); browser.error = message
                    }
                }.ignoresSafeArea()
            }
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())
    }
    private var home: some View {
        #if os(tvOS)
        HStack(spacing: 70 * homeScale) {
            homeLink("Files", symbol: "folder", destination: .files)
            homeLink("Favorites", symbol: "star", destination: .favorites)
            homeLink("Watching", symbol: "play.rectangle", destination: .watching)
            homeLink("Settings", symbol: "gearshape", destination: .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        #else
        List {
            NavigationLink(value: Destination.files) { Label("Files", systemImage: "folder") }
            NavigationLink(value: Destination.favorites) { Label("Favorites", systemImage: "star") }
            NavigationLink(value: Destination.watching) { Label("Watching", systemImage: "play.rectangle") }
            NavigationLink(value: Destination.settings) { Label("Settings", systemImage: "gearshape") }
        }
        .navigationTitle("BoraMin")
        .scrollContentBackground(.hidden)
        .background(Color.black)
        #endif
    }
    private let homeScale: CGFloat = 0.65
    private func homeLink(_ name: String, symbol: String, destination: Destination) -> some View {
        NavigationLink(value: destination) {
            VStack(spacing: 24 * homeScale) {
                Image(systemName: symbol).font(.system(size: 76 * homeScale))
                Text(name).font(.system(size: UIFont.preferredFont(forTextStyle: .title2).pointSize * homeScale))
            }
            .frame(width: 270 * homeScale, height: 240 * homeScale)
            .padding(24 * homeScale)
            .foregroundStyle(focusedHome == destination ? Color.black : Color.white)
            .background(focusedHome == destination ? Color(white: 0.95) : Color(white: 32.0 / 255),
                        in: RoundedRectangle(cornerRadius: 20 * homeScale))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .hoverEffectDisabled()
        .focused($focusedHome, equals: destination)
    }
    private var files: some View {
        Group {
            if navigation.last == .files && browser.connectionNeedsSetup { connection }
            else if !browser.connected {
                ContentUnavailableView {
                    Label("Connecting to server", systemImage: "externaldrive.connected.to.line.below")
                } description: {
                    Text(browser.connectionNeedsSetup ? "Check your server and account details in Connection Setup." :
                         (browser.connectionError.map { "\($0)\nRetrying automatically…" } ?? "Using your saved connection details."))
                } actions: {
                    Button("Connection Setup") { navigation.append(.connectionSetup) }
                }
            }
            else {
                    List {
                        Group {
                        Button(atFavoriteRoot ? "Back to Favorites" : (browser.path.isEmpty ? "Back" : "Parent folder"), systemImage: "chevron.left") { navigateBack() }
                            .browserDefaultFocus(browser.share.isEmpty ? browser.shares.isEmpty : firstFocusableEntry == nil, in: listingFocus)
                        if browser.share.isEmpty {
                            ForEach(browser.shares, id: \.self) { share in
                                Button(share, systemImage: "externaldrive.connected.to.line.below") { browser.openShare(share) }
                                    .browserDefaultFocus(share == browser.shares.first, in: listingFocus)
                                    .contextMenu { favoriteMenu(browser.favoriteShare(share)) }
                            }
                            if browser.shares.isEmpty { Text("No shares found. Reconnect with a share name.") }
                        } else {
                            ForEach(visibleEntries) { entry in
                                Button {
                                    if entry.directory { browser.openDirectory(entry.path) } else { browser.play(entry) }
                                } label: {
                                    HStack {
                                        Image(systemName: entry.directory ? "folder" : "film")
                                        Text(entry.displayName)
                                        Spacer()
                                        if !entry.directory { Text(entry.sizeAndDuration).foregroundStyle(.secondary) }
                                    }
                                }.disabled(!entry.directory && !entry.playable)
                                    .task(id: entry.id) { await browser.loadDuration(entry) }
                                    .browserDefaultFocus(entry.id == firstFocusableEntry, in: listingFocus)
                                    .contextMenu {
                                        if entry.directory { favoriteMenu(browser.favoriteLocation(path: entry.path)) }
                                        else {
                                            Button("Delete File…", systemImage: "trash", role: .destructive) { fileToDelete = entry }
                                        if entry.playable {
                                            Button("Reset playback", systemImage: "arrow.counterclockwise") {
                                                browser.resetPlayback(entry)
                                            }
                                            .disabled(entry.progress == nil)
                                        }
                                        }
                                    }
                            }
                            if visibleEntries.isEmpty {
                                Text(browser.entries.isEmpty ? "This folder is empty." : "No playable media in this folder.")
                            }
                        }
                        }
                    }
                    .listStyle(.plain)
                    #if os(iOS)
                    .scrollContentBackground(.hidden)
                    #endif
                    .buttonBorderShape(.roundedRectangle)
                    .background(Color.black)
                    .browserFocusScope(listingFocus)
                    // A new directory gets a fresh list and its preferred initial focus.
                    .id([browser.share, browser.path, displayAllFiles ? "all" : "media"])
                    .browserExitCommand {
                        guard !browser.busy, browser.playing == nil else { return }
                        navigateBack()
                    }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let activeBrowser = browser
            let usingSavedConnection = navigation.last == .files
            activeBrowser.refreshConnection()
            while !Task.isCancelled {
                if !activeBrowser.connected {
                    await activeBrowser.automaticallyConnect(usingSavedConnection: usingSavedConnection)
                }
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
    }
    private var settings: some View {
        List {
            Section {
                NavigationLink("Connection Setup", value: Destination.connectionSetup)
            }

            Section {
                Toggle("Sync via iCloud",isOn:Binding(get:{cloud.enabled},set:{cloud.setEnabled($0)}))
                    .toggleStyle(.switch)
                if cloud.enabled {
                    Text(cloud.status).font(.caption).foregroundStyle(.secondary)
                    if let lastSync=cloud.lastSync { Text("Last synced \(lastSync.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
                    Button("Sync now") { Task { await cloud.synchronize() } }.disabled(cloud.syncing)
                }
            } footer: {
                Text("Sync connections, encrypted passwords, favorites, playback positions and preferences across your devices. Turning this off keeps your local data.")
            }
            Section {
                Toggle("Display all files", isOn: $displayAllFiles)
                    .toggleStyle(.switch)
            } footer: {
                Text("Show other files alongside folders and supported videos. Hidden files stay hidden.")
            }
            Section {
                Toggle("Show Debug Info", isOn: $showDebugInfo)
                    .toggleStyle(.switch)
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .background(Color.black.ignoresSafeArea())
    }
    private var favoritesList: some View {
        Group {
            if favorites.locations.isEmpty {
                ContentUnavailableView("No Favorites", systemImage: "star", description:
                    Text("In Files, press and hold a folder or share and choose Favorite."))
            } else {
                List(favorites.locations) { favorite in
                    Button {
                        favoriteBrowser.useCredentials(from: filesBrowser)
                        favoriteBrowser.openFavorite(favorite) { navigation.append(.favoriteFiles(favorite)) }
                    } label: {
                        HStack(spacing: 24) {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(favorite.name)
                                Text(favorite.location).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Remove favorite", systemImage: "star.slash", role: .destructive) {
                            favorites.remove(favorite)
                        }
                    }
                }
                .listStyle(.plain)
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
    private var watchingList: some View {
        Group {
            if watching.isEmpty {
                ContentUnavailableView("Nothing in Progress", systemImage: "play.rectangle",
                    description: Text("Videos with a saved playback position appear here."))
            } else {
                List(watching) { video in
                    Button {
                        if let file = video.file { watchingBrowser.openWatching(file) }
                    } label: {
                        HStack(spacing: 24) {
                            Image(systemName: "film")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(video.progress.prefix) \(video.file?.name ?? "Saved video · \(video.id.prefix(6))")")
                                if let file = video.file {
                                    Text(BrowserEntry(name: file.name, path: file.path, directory: false, size: file.size, duration: video.progress.duration).sizeAndDuration).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(video.file?.location ?? "Open this video's folder in Files to recover its name and location.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(video.file == nil)
                    .contextMenu {
                        Button("Reset playback", systemImage: "arrow.counterclockwise") {
                            PlaybackPositions.shared.clear(video.id)
                            watching = PlaybackPositions.shared.watching()
                        }
                    }
                }
                .listStyle(.plain)
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { watching = PlaybackPositions.shared.watching() }
        .task {
            watchingBrowser.useCredentials(from: filesBrowser)
            for location in favorites.locations {
                guard !Task.isCancelled, watching.contains(where: { $0.file == nil }) else { return }
                await watchingBrowser.recoverWatchingMetadata(at: location)
                watching = PlaybackPositions.shared.watching()
            }
        }
    }
    @ViewBuilder private func favoriteMenu(_ location: FavoriteLocation?) -> some View {
        if let location {
            Button("Favorite", systemImage: "star") { favorites.add(location) }
                .disabled(favorites.contains(location))
        }
    }
    private func navigateBack() {
        guard !browser.busy, browser.playing == nil else { return }
        if atFavoriteRoot {
            navigation.removeLast()
        } else if !browser.path.isEmpty || (!browser.share.isEmpty && browser.directShare.isEmpty) {
            browser.back()
        } else if !navigation.isEmpty {
            navigation.removeLast()
        }
    }
    private var connection: some View {
        ConnectionSetupScreen(browser: filesBrowser) {
            if navigation.last == .connectionSetup { navigation.removeLast() }
            if navigation.last != .files { navigation.append(.files) }
        }
    }
}

private struct ConnectionSetupScreen: View {
    @ObservedObject var browser: Browser
    let onConnect: @MainActor () -> Void
    @State private var host: String
    @State private var username: String
    @State private var password: String
    @State private var domain: String
    @State private var share: String

    init(browser: Browser, onConnect: @escaping @MainActor () -> Void) {
        self.browser = browser; self.onConnect = onConnect
        _host = State(initialValue: browser.host)
        _username = State(initialValue: browser.username)
        _password = State(initialValue: browser.password)
        _domain = State(initialValue: browser.domain)
        _share = State(initialValue: browser.directShare)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect to an SMB server").font(.title2)
                TextField("Server · nas.local or 192.168.1.10", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username · leave empty for guest", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
                TextField("Domain · optional", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Share · optional, otherwise list shares", text: $share).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect") {
                    browser.connect(host: host, username: username, domain: domain, password: password,
                                    directShare: share, onConnect: onConnect)
                }.disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Connection details are remembered after connecting. Your password is saved securely in Keychain.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 1100)
                #if os(tvOS)
                .padding(60)
                #else
                .padding(24)
                #endif
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private extension View {
    @ViewBuilder func browserDefaultFocus(_ preferred: Bool, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        prefersDefaultFocus(preferred, in: namespace)
        #else
        self
        #endif
    }
    @ViewBuilder func browserFocusScope(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        focusScope(namespace)
        #else
        self
        #endif
    }
    @ViewBuilder func browserExitCommand(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

#endif
