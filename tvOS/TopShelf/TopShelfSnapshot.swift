import Foundation

/// Only display names, opaque bookmark IDs and local image filenames cross the extension boundary.
struct TopShelfEntry: Codable, Equatable {
    let id: String
    let title: String
    var artwork: String? = nil
}

enum TopShelfSnapshot {
    static var url: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BoraMinAppGroup") as? String, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
            .appendingPathComponent("watching.json")
    }
    static func artworkURL(_ filename: String) -> URL? {
        // A content hash, never a remote path or an arbitrary relative filename.
        guard isArtworkFilename(filename) else { return nil }
        return url?.deletingLastPathComponent().appendingPathComponent(filename)
    }
    static func isArtworkFilename(_ filename: String) -> Bool {
        let stem = String(filename.dropLast(4))
        return filename.hasSuffix(".png") && stem.count == 64 &&
            stem.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func actionURL(for id: String) -> URL? {
        var url = URLComponents()
        url.scheme = "boramin"
        url.host = "watching"
        url.queryItems = [URLQueryItem(name: "id", value: id)]
        return url.url
    }
}
