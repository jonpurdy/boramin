import Foundation
import CryptoKit

/// Portable subtitle identity stored only alongside an unfinished bookmark.
struct SavedSubtitleSelection: Codable, Equatable {
    enum Kind: String, Codable { case off, external, engine, native }
    let kind: Kind
    var filename: String?
    var stream: Int?
    var name: String?
    var language: String?
    var codec: String?
    var nativePropertyList: Data?
    var nativeSubtypes: [UInt32]?
    var forced: Bool?
    var encoded: String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let bytes = try? encoder.encode(self), bytes.count <= 65536 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    static func decode(_ value: String?) -> Self? {
        guard let value, let bytes = value.data(using: .utf8), bytes.count <= 65536,
              let result = try? JSONDecoder().decode(Self.self, from: bytes) else { return nil }
        switch result.kind {
        case .off: return result
        case .external:
            guard let filename = result.filename, !filename.isEmpty, filename.utf8.count <= 4096,
                  (filename as NSString).lastPathComponent == filename else { return nil }
        case .engine:
            guard let stream = result.stream, stream >= 0, result.codec != nil else { return nil }
        case .native:
            guard result.nativePropertyList != nil || result.name != nil else { return nil }
        }
        return result
    }
}

struct PlaybackProgress {
    let seconds: Double
    let duration: Double
    var prefix: String {
        let percent = min(99, max(0, Int(seconds / duration * 100)))
        let whole = Int(seconds)
        return String(format: "(%d%%, %02d:%02d:%02d)", percent, whole / 3600, whole / 60 % 60, whole % 60)
    }
}

/// Small, local bookmarks; all read/modify/write operations run on the main actor.
@MainActor final class PlaybackPositions {
    static let shared = PlaybackPositions()
    private let defaults: UserDefaults
    private let storageKey = "playbackPositions.v1"
    private let limit = 500
    static let subtitleStorageKey = "playbackSubtitles.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    nonisolated static func key(server: URL, share: String, path: String, size: Int64) -> String {
        // Identify the original SMB file, not the per-play loopback URL. No
        // credentials are included in the bookmark identity. Display/reopen metadata
        // is stored separately, without passwords.
        let components = [server.host?.lowercased() ?? "", String(server.port ?? 445),
                          share.lowercased(), path, String(size)]
        return SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func position(for key: String, duration: Double) -> Double? {
        guard let progress = progress(for: key), duration.isFinite, duration > progress.seconds else { return nil }
        return progress.seconds
    }

    func progress(for key: String) -> PlaybackProgress? {
        decode(defaults.dictionary(forKey: storageKey)?[key] as? [String: Double])
    }

    func allProgress() -> [String: PlaybackProgress] {
        let records = defaults.dictionary(forKey: storageKey) as? [String: [String: Double]] ?? [:]
        return records.compactMapValues { decode($0) }
    }

    private func decode(_ record: [String: Double]?) -> PlaybackProgress? {
        guard let record,
              let seconds = record["seconds"], let duration = record["duration"],
              seconds.isFinite, duration.isFinite, seconds > 0, seconds < duration,
              seconds < Double(Int.max / 4) else { return nil }
        return PlaybackProgress(seconds: seconds, duration: duration)
    }

    func save(_ seconds: Double, duration: Double, for key: String, subtitle: SavedSubtitleSelection? = nil) {
        guard seconds.isFinite, duration.isFinite, duration > 0, seconds >= 0 else { return }
        guard seconds > 0, seconds < duration else { clear(key); return }
        var records = defaults.dictionary(forKey: storageKey) as? [String: [String: Double]] ?? [:]
        records[key] = ["seconds": seconds, "duration": duration, "updated": Date().timeIntervalSince1970]
        if records.count > limit {
            let oldest = records.keys.sorted { (records[$0]?["updated"] ?? 0) < (records[$1]?["updated"] ?? 0) }
            for key in oldest.prefix(records.count - limit) { records.removeValue(forKey: key) }
        }
        defaults.set(records, forKey: storageKey)
        var subtitles = defaults.dictionary(forKey: Self.subtitleStorageKey) as? [String: String] ?? [:]
        if let encoded = subtitle?.encoded { subtitles[key] = encoded }
        subtitles = subtitles.filter { records[$0.key] != nil }
        defaults.set(subtitles, forKey: Self.subtitleStorageKey)
        var resets=defaults.dictionary(forKey:"playbackResets.v1") as? [String:Double] ?? [:]
        if resets.removeValue(forKey:key) != nil { defaults.set(resets,forKey:"playbackResets.v1") }
    }

    func clear(_ key: String) {
        var records = defaults.dictionary(forKey: storageKey) ?? [:]
        records.removeValue(forKey: key)
        defaults.set(records, forKey: storageKey)
        var subtitles = defaults.dictionary(forKey: Self.subtitleStorageKey) as? [String: String] ?? [:]
        subtitles.removeValue(forKey: key)
        defaults.set(subtitles, forKey: Self.subtitleStorageKey)
        var resets=defaults.dictionary(forKey:"playbackResets.v1") as? [String:Double] ?? [:]
        resets[key]=Date().timeIntervalSince1970
        if resets.count>500 {
            for key in resets.keys.sorted(by:{ resets[$0]! > resets[$1]! }).dropFirst(500) { resets.removeValue(forKey:key) }
        }
        defaults.set(resets,forKey:"playbackResets.v1")
    }
    func subtitleSelection(for key: String) -> SavedSubtitleSelection? {
        guard progress(for: key) != nil else { return nil }
        return SavedSubtitleSelection.decode(defaults.dictionary(forKey: Self.subtitleStorageKey)?[key] as? String)
    }
    /// Selecting subtitles never creates a Watching entry on its own.
    func saveSubtitle(_ selection: SavedSubtitleSelection, for key: String) {
        guard let progress = progress(for: key), subtitleSelection(for: key) != selection else { return }
        save(progress.seconds, duration: progress.duration, for: key, subtitle: selection)
    }
    /// Apply the subtitle field from the SAME cloud position record, retaining its timestamp.
    func applySyncedSubtitle(_ encoded: String?, for key: String) {
        var subtitles = defaults.dictionary(forKey: Self.subtitleStorageKey) as? [String: String] ?? [:]
        subtitles[key] = progress(for: key) == nil ? nil : SavedSubtitleSelection.decode(encoded)?.encoded
        let active = Set(allProgress().keys)
        defaults.set(subtitles.filter { active.contains($0.key) }, forKey: Self.subtitleStorageKey)
    }
}

/// SMB location metadata for displaying and reopening a bookmark; never stores passwords.
struct PlaybackFile: Codable, Equatable {
    let server: String
    let share: String
    let path: String
    let size: Int64
    let username: String
    let domain: String
    var name: String { (path as NSString).lastPathComponent }
    var folderLocation: String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "\(server)/\(share)" : "\(server)/\(share)/\(folder)"
    }
    var key: String { PlaybackPositions.key(server: URL(string: server)!, share: share, path: path, size: size) }
    var fields: [String: String] {
        ["server": server, "share": share, "path": path, "size": String(size), "username": username, "domain": domain]
    }
    init?(server: URL, share: String, path: String, size: Int64, username: String, domain: String) {
        guard server.scheme == "smb", let host = server.host, !host.isEmpty,
              !share.isEmpty, !path.isEmpty, size > 0 else { return nil }
        var clean = URLComponents()
        clean.scheme = "smb"; clean.host = host.lowercased()
        clean.port = server.port == 445 ? nil : server.port
        guard let address = clean.string else { return nil }
        self.server = address; self.share = share; self.path = path; self.size = size
        self.username = username; self.domain = domain
    }
    init?(fields: [String: String]) {
        guard let server = fields["server"].flatMap(URL.init(string:)), let share = fields["share"],
              let path = fields["path"], let size = fields["size"].flatMap(Int64.init) else { return nil }
        self.init(server: server, share: share, path: path, size: size,
                  username: fields["username"] ?? "", domain: fields["domain"] ?? "")
    }
}

struct WatchingVideo: Identifiable {
    let id: String
    let file: PlaybackFile?
    let progress: PlaybackProgress
    let lastSaved: Double
}

extension PlaybackPositions {
    func allFiles() -> [String: PlaybackFile] {
        let fields = defaults.dictionary(forKey: "playbackFiles.v1") as? [String: [String: String]] ?? [:]
        return fields.reduce(into: [:]) { result, item in
            if let file = PlaybackFile(fields: item.value), file.key == item.key { result[item.key] = file }
        }
    }
    func remember(_ file: PlaybackFile) {
        var files = defaults.dictionary(forKey: "playbackFiles.v1") as? [String: [String: String]] ?? [:]
        guard files[file.key] != file.fields else { return }
        files[file.key] = file.fields
        // Keep metadata bounded alongside the 500 bookmarks, plus the video opening now.
        if files.count > limit + 1 {
            let active = Set(allProgress().keys).union([file.key])
            let unused = files.keys.filter { !active.contains($0) }.sorted()
            for key in unused.prefix(files.count - limit - 1) { files.removeValue(forKey: key) }
        }
        defaults.set(files, forKey: "playbackFiles.v1")
    }
    func forgetFile(_ key: String) {
        var files = defaults.dictionary(forKey: "playbackFiles.v1") ?? [:]
        guard files.removeValue(forKey: key) != nil else { return }
        defaults.set(files, forKey: "playbackFiles.v1")
    }
    func watching() -> [WatchingVideo] {
        let files = allFiles()
        let records = defaults.dictionary(forKey: storageKey) as? [String: [String: Double]] ?? [:]
        return allProgress().map { key, progress in
            let updated = records[key]?["updated"] ?? 0
            return WatchingVideo(id: key, file: files[key], progress: progress, lastSaved: updated.isFinite ? updated : 0)
        }.sorted { $0.lastSaved == $1.lastSaved ? $0.id < $1.id : $0.lastSaved > $1.lastSaved }
    }
}
