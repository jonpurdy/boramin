import Foundation
import Combine

@main struct MediaMetadataTests {
    @MainActor static func main() {
        for ext in ["mp4", "M4V", "mov"] {
            precondition(PlaybackRoute.expected(fileExtension: ext, vp9: true) == .hardwareVP9)
            precondition(PlaybackRoute.expected(fileExtension: ext, vp9: false) == .avPlayer)
            precondition(PlaybackRoute.expected(fileExtension: ext, vp9: nil) == nil)
        }
        for ext in ["mkv", "WEBM"] {
            precondition(PlaybackRoute.expected(fileExtension: ext, vp9: true) == .hardwareVP9)
            precondition(PlaybackRoute.expected(fileExtension: ext, vp9: false) == .aether)
            precondition(PlaybackRoute.expected(fileExtension: ext, vp9: nil) == nil)
        }
        precondition(PlaybackRoute.expected(fileExtension: "avi", vp9: nil) == .aether)
        precondition(PlaybackRoute.expected(fileExtension: "ts", vp9: true) == .aether)
        let domain = "BoraMin.MetadataTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let cache = MediaMetadataCache(defaults: defaults, limit: 2)
        var changes = 0
        let observer = cache.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }
        let server = URL(string: "smb://example.invalid")!
        let key = MediaMetadataCache.key(server: server, connectionID: "a", share: "Media", path: "movie.mkv", size: 10)
        cache.save(duration: 120, route: .hardwareVP9, modified: 1, for: key)
        precondition(changes > 0, "Watching details must receive cache publication when the label is discovered")
        precondition(cache.value(for: key, modified: 1)?.duration == 120)
        precondition(cache.value(for: key, modified: 2) == nil)
        precondition(MediaMetadataCache(defaults: defaults).value(for: key)?.route == .hardwareVP9)
        for otherKey in [
            MediaMetadataCache.key(server: server, connectionID: "b", share: "Media", path: "movie.mkv", size: 10),
            MediaMetadataCache.key(server: server, connectionID: "a", share: "Media", path: "movie.mkv", size: 11),
            MediaMetadataCache.key(server: URL(string: "smb://other.invalid")!, connectionID: "a", share: "Media", path: "movie.mkv", size: 10)
        ] { precondition(cache.value(for: otherKey) == nil) }
        cache.save(duration: .nan, route: .aether, modified: 2, for: key)
        precondition(cache.value(for: key, modified: 2)?.duration == nil)
        precondition(cache.value(for: key)?.route == .aether)
        cache.save(duration: 1, route: .avPlayer, modified: 1, for: "second")
        cache.save(duration: 1, route: .aether, modified: 1, for: "third")
        precondition(cache.value(for: key) == nil && cache.value(for: "second") != nil && cache.value(for: "third") != nil)
        let json = String(data: defaults.data(forKey: "mediaMetadata.v1")!, encoding: .utf8)!
        precondition(!json.contains("example.invalid") && !json.contains("movie.mkv"))
        print("PASS: expected route matrix, local persistence, changed file/account/server invalidation, invalid duration and bounded metadata eviction")
    }
}
