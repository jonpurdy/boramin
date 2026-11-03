import Foundation

/// Only display names and opaque bookmark IDs cross the extension boundary.
struct TopShelfEntry: Codable, Equatable {
    let id: String
    let title: String
}

enum TopShelfSnapshot {
    static let group = "group.com.example.BoraMin"
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
            .appendingPathComponent("watching.json")
    }
    static func actionURL(for id: String) -> URL? {
        var url = URLComponents()
        url.scheme = "boramin"
        url.host = "watching"
        url.queryItems = [URLQueryItem(name: "id", value: id)]
        return url.url
    }
}
