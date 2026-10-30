import Foundation
import Combine

struct FavoriteLocation: Codable, Identifiable, Hashable {
    let server: String
    let share: String
    let path: String
    let connectionID: String?
    let identity: String?

    var id: String { identity ?? [connectionID ?? server, share.lowercased(), path].joined(separator: "\0") }
    var name: String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        if !share.isEmpty { return share }
        let root = URL(string: server)
        return root?.path.split(separator: "/").last.map(String.init) ?? root?.host ?? server
    }
    var location: String {
        if let root = URL(string: server), root.scheme != "smb" {
            return path.isEmpty ? server : root.appendingPathComponent(path).absoluteString
        }
        return "\(server)/\(share)\(path.isEmpty ? "" : "/\(path)")"
    }

    static func alphabeticallyPrecedes(_ lhs: FavoriteLocation, _ rhs: FavoriteLocation) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.location < rhs.location : order == .orderedAscending
    }

    init?(server: URL, share: String, path: String, connectionID: String? = nil, identity: String? = nil) {
        if ["http", "https"].contains(server.scheme ?? "") {
            guard share.isEmpty, server.user == nil, server.password == nil, server.query == nil, server.fragment == nil,
                  server.host != nil else { return nil }
            self.server = server.absoluteString; self.share = ""; self.path = path
            self.connectionID = connectionID; self.identity = identity
            return
        }
        guard server.scheme == "smb", let host = server.host, !host.isEmpty, !share.isEmpty else { return nil }
        // Store locations only, never URL credentials or passwords.
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host.lowercased()
        components.port = server.port == 445 ? nil : server.port
        guard let address = components.string else { return nil }
        self.server = address
        self.share = share
        self.path = path
        self.connectionID = connectionID; self.identity = identity
    }
}

@MainActor final class Favorites: ObservableObject {
    @Published private(set) var locations: [FavoriteLocation]
    private let defaults: UserDefaults
    private let storageKey = "favoriteLocations.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        locations = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([FavoriteLocation].self, from: $0) } ?? []
        sort()
    }

    func add(_ location: FavoriteLocation) {
        guard !contains(location) else { return }
        locations.append(location)
        sort()
        if let data = try? JSONEncoder().encode(locations) { defaults.set(data, forKey: storageKey) }
    }

    func remove(_ location: FavoriteLocation) {
        guard contains(location) else { return }
        locations.removeAll { Self.sameLocation($0, location) }
        if let data = try? JSONEncoder().encode(locations) { defaults.set(data, forKey: storageKey) }
    }

    func contains(_ location: FavoriteLocation) -> Bool { locations.contains { Self.sameLocation($0, location) } }
    private static func sameLocation(_ left: FavoriteLocation, _ right: FavoriteLocation) -> Bool {
        if left.id == right.id { return true }
        guard left.share.caseInsensitiveCompare(right.share) == .orderedSame, left.path == right.path else { return false }
        if let a = left.connectionID, let b = right.connectionID { return a == b }
        return left.server == right.server
    }

    func reload() {
        let saved=defaults.data(forKey:storageKey).flatMap { try? JSONDecoder().decode([FavoriteLocation].self,from:$0) } ?? []
        if saved != locations { locations=saved; sort() }
    }

    private func sort() {
        locations.sort(by: FavoriteLocation.alphabeticallyPrecedes)
    }
}
