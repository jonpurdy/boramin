import Foundation
import CryptoKit
import Combine

enum PlaybackRoute: String, Codable {
    case avPlayer = "AVP", aether = "AEP", hardwareVP9 = "HW9"

    /// Expected production route, not a guarantee that this codec/profile will play.
    static func expected(fileExtension: String, vp9: Bool?) -> Self? {
        let ext = fileExtension.lowercased()
        if ["mp4", "m4v", "mov", "mkv", "webm"].contains(ext) {
            guard let vp9 else { return nil }
            if vp9 { return .hardwareVP9 }
            return ["mp4", "m4v", "mov"].contains(ext) ? .avPlayer : .aether
        }
        return .aether
    }
}

/// Local, bounded metadata only. Not included in the CloudKit snapshots.
@MainActor final class MediaMetadataCache: ObservableObject {
    static let shared = MediaMetadataCache()
    struct Record: Codable {
        var duration: Double?
        var route: PlaybackRoute
        var modified: Double
        var stored: Double
    }
    private let defaults: UserDefaults
    private let limit: Int
    private let storageKey = "mediaMetadata.v1"
    @Published private var records: [String: Record]
    init(defaults: UserDefaults = .standard, limit: Int = 1000) {
        self.defaults = defaults; self.limit = max(1, limit)
        records = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    nonisolated static func key(server: URL, connectionID: String?, share: String, path: String, size: Int64) -> String {
        let parts = [connectionID ?? "", server.host?.lowercased() ?? "", String(server.port ?? 445), share.lowercased(), path, String(size)]
        return SHA256.hash(data: Data(parts.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func value(for key: String, modified: Double? = nil) -> Record? {
        guard let record = records[key], modified == nil || record.modified == modified else { return nil }
        return record
    }
    func save(duration: Double?, route: PlaybackRoute, modified: Double, for key: String) {
        guard modified.isFinite else { return }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        records[key] = Record(duration: duration, route: route, modified: modified, stored: Date().timeIntervalSince1970)
        if records.count > limit {
            for key in records.keys.sorted(by: { records[$0]!.stored > records[$1]!.stored }).dropFirst(limit) { records.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: storageKey) }
    }
}
