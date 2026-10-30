import Foundation

@main struct FavoritesTests {
    @MainActor static func main() {
        let suite = "BoraMin.FavoritesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Favorites(defaults: defaults)
        let folder = FavoriteLocation(server: URL(string: "smb://user:secret@NAS.local:445")!, share: "Movies", path: "日本語/Folder 2")!
        let duplicate = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "movies", path: "日本語/Folder 2")!
        let share = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "Archive", path: "")!
        store.add(folder)
        store.add(duplicate)
        store.add(share)
        precondition(store.locations.count == 2 && store.contains(duplicate))
        precondition(store.locations.first == share)
        precondition(folder.server == "smb://nas.local")
        precondition(folder.name == "Folder 2" && share.name == "Archive")
        let reopened = Favorites(defaults: UserDefaults(suiteName: suite)!)
        precondition(reopened.locations == store.locations)
        let json = String(data: defaults.data(forKey: "favoriteLocations.v1")!, encoding: .utf8)!
        precondition(!json.contains("secret") && !json.contains("user"))
        let otherServer = FavoriteLocation(server: URL(string: "smb://other.local:1445")!, share: folder.share, path: folder.path)!
        store.add(otherServer)
        precondition(store.locations.count == 3 && otherServer.id != folder.id)
        reopened.reload()
        precondition(reopened.locations == store.locations)
        store.remove(folder)
        precondition(!store.contains(folder) && store.contains(otherServer) && store.locations.count == 2)
        let afterRemoval = Favorites(defaults: UserDefaults(suiteName: suite)!)
        precondition(afterRemoval.locations == store.locations)
        reopened.reload()
        precondition(reopened.locations == store.locations)
        store.remove(folder) // Removing an absent favorite is harmless.
        precondition(store.locations.count == 2)

        let alpha = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "Media", path: "alpha")!
        let two = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "Media", path: "Folder 2")!
        let ten = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "Media", path: "Folder 10")!
        let zulu = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "Media", path: "Zulu")!
        // Simulate records arriving from iCloud in insertion/date order.
        defaults.set(try! JSONEncoder().encode([zulu, ten, two, alpha]), forKey: "favoriteLocations.v1")
        reopened.reload()
        precondition(reopened.locations == [alpha, two, ten, zulu])
        precondition(Favorites(defaults: defaults).locations == [alpha, two, ten, zulu])
        precondition(FavoriteLocation(server: URL(string: "https://nas.local")!, share: "Movies", path: "") == nil)
        let httpRoot = URL(string: "https://nas.local/media/")!
        let httpFavorite = FavoriteLocation(server: httpRoot, share: "", path: "日本語/Folder 2", connectionID: "http")!
        let httpBase = FavoriteLocation(server: httpRoot, share: "", path: "", connectionID: "http")!
        precondition(httpBase.name == "media" && httpFavorite.name == "Folder 2")
        precondition(httpFavorite.location.hasPrefix(httpRoot.absoluteString))
        precondition(FavoriteLocation(server: URL(string: "https://user:secret@nas.local/")!, share: "", path: "") == nil)
        store.add(httpFavorite); store.add(httpBase)
        precondition(Favorites(defaults: defaults).contains(httpFavorite))
        let connectionA = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "Media", path: "shared", connectionID: "a")!
        let connectionB = FavoriteLocation(server: URL(string: "smb://nas.local")!, share: "Media", path: "shared", connectionID: "b")!
        store.add(connectionA); store.add(connectionB)
        precondition(connectionA.id != connectionB.id && store.contains(connectionA) && store.contains(connectionB))
        let originalID = "legacy-identity"
        let migratedFavorite = FavoriteLocation(server: URL(string: "smb://old.invalid")!, share: "Media", path: "shared", connectionID: "a", identity: originalID)!
        let roundTrip = try! JSONDecoder().decode(FavoriteLocation.self, from: JSONEncoder().encode(migratedFavorite))
        precondition(roundTrip.id == originalID && roundTrip.connectionID == "a")
        store.add(migratedFavorite)
        precondition(store.contains(migratedFavorite), "Migrated identities must match the same connection/path")
        print("PASS: favorites persist, sort, distinguish server/account connections, preserve migrated IDs and omit credentials")
    }
}
