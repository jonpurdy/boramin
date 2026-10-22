import Foundation
import Combine

struct FavoriteLocation: Codable, Identifiable, Hashable {
    let server: String
    let share: String
    let path: String

    var id: String { [server, share.lowercased(), path].joined(separator: "\0") }
    var name: String { path.isEmpty ? share : (path as NSString).lastPathComponent }
    var location: String { "\(server)/\(share)\(path.isEmpty ? "" : "/\(path)")" }

    static func alphabeticallyPrecedes(_ lhs: FavoriteLocation, _ rhs: FavoriteLocation) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.location < rhs.location : order == .orderedAscending
    }

    init?(server: URL, share: String, path: String) {
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
        guard !locations.contains(where: { $0.id == location.id }) else { return }
        locations.append(location)
        sort()
        if let data = try? JSONEncoder().encode(locations) { defaults.set(data, forKey: storageKey) }
    }

    func remove(_ location: FavoriteLocation) {
        guard contains(location) else { return }
        locations.removeAll { $0.id == location.id }
        if let data = try? JSONEncoder().encode(locations) { defaults.set(data, forKey: storageKey) }
    }

    func contains(_ location: FavoriteLocation) -> Bool { locations.contains { $0.id == location.id } }

    func reload() {
        let saved=defaults.data(forKey:storageKey).flatMap { try? JSONDecoder().decode([FavoriteLocation].self,from:$0) } ?? []
        if saved != locations { locations=saved; sort() }
    }

    private func sort() {
        locations.sort(by: FavoriteLocation.alphabeticallyPrecedes)
    }
}
