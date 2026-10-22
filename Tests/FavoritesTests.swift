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
        print("PASS: favorites persist, remove and reload, sort incoming records alphabetically with natural numbers, deduplicate normalized locations, distinguish servers and omit credentials")
    }
}
