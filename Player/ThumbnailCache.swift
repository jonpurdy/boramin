import Foundation
import ImageIO
import UniformTypeIdentifiers

struct EmbeddedArtworkResult {
    let png: Data?
}

/// Disposable device-local artwork. Never part of CloudKit or playback snapshots.
@MainActor final class ThumbnailCache {
    static let shared = ThumbnailCache()
    struct Record: Codable {
        let modified: Double
        let stored: Double
        let bytes: Int
    }
    private let directory: URL
    private let byteLimit: Int
    private let entryLimit: Int
    private var records: [String: Record]
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EmbeddedArtwork-v1", isDirectory: true), byteLimit: Int = 64 * 1024 * 1024, entryLimit: Int = 1000) {
        self.directory = directory; self.byteLimit = byteLimit; self.entryLimit = entryLimit
        records = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    private func validKey(_ key: String) -> Bool {
        key.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func url(_ key: String) -> URL { directory.appendingPathComponent(key + ".png") }
    func contains(_ key: String, modified: Double? = nil) -> Bool {
        guard validKey(key), let record = records[key], modified == nil || record.modified == modified else { return false }
        // Revisit negative results periodically, without re-probing every shelf refresh.
        if record.bytes == 0 { return Date().timeIntervalSince1970 - record.stored < 7 * 86400 }
        return FileManager.default.fileExists(atPath: url(key).path)
    }
    func data(for key: String) -> Data? {
        guard contains(key), records[key]?.bytes ?? 0 > 0 else { return nil }
        return try? Data(contentsOf: url(key))
    }
    func invalidate(_ key: String) {
        guard validKey(key) else { return }
        records.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: url(key))
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: indexURL, options: .atomic) }
    }
    func save(_ result: EmbeddedArtworkResult, for key: String, modified: Double) {
        guard validKey(key), modified.isFinite else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let png = result.png { try png.write(to: url(key), options: .atomic) }
            else { try? FileManager.default.removeItem(at: url(key)) }
            records[key] = Record(modified: modified, stored: Date().timeIntervalSince1970, bytes: result.png?.count ?? 0)
            var bytes = records.values.reduce(0) { $0 + $1.bytes }
            for victim in records.keys.sorted(by: { records[$0]!.stored < records[$1]!.stored }) {
                guard records.count > entryLimit || bytes > byteLimit else { break }
                bytes -= records.removeValue(forKey: victim)?.bytes ?? 0
                try? FileManager.default.removeItem(at: url(victim))
            }
            // Drop orphan images left by an interrupted index write or a purged index.
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "png" && records[file.deletingPathExtension().lastPathComponent] == nil {
                try? FileManager.default.removeItem(at: file)
            }
            try JSONEncoder().encode(records).write(to: indexURL, options: .atomic)
        } catch { /* Caches are optional; retry on a later request. */ }
    }
    nonisolated static func downsample(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64 * 1024 * 1024,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
