import Foundation
import Security

@main struct ConnectionPreferencesTests {
    @MainActor static func main() throws {
        let suite = "BoraMin.ConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: suite] as CFDictionary)
        }
        let store = ConnectionPreferences(defaults: defaults, service: suite)
        precondition(defaults.string(forKey: "server") == nil)
        precondition(store.password(address: "", username: "", domain: "") == nil)
        let server = URL(string: "smb://example.invalid")!
        try store.save(server: server, username: "test-user", domain: "TEST", share: "Media", password: " synthetic password \n")
        let reopened = ConnectionPreferences(defaults: UserDefaults(suiteName: suite)!, service: suite)
        precondition(reopened.password(address: "EXAMPLE.invalid:445", username: "test-user", domain: "test") == " synthetic password \n")
        precondition(defaults.string(forKey: "server") == server.absoluteString)
        precondition(defaults.string(forKey: "share") == "Media")
        precondition(defaults.string(forKey: "password") == nil)
        precondition(reopened.password(address: "other.invalid", username: "test-user", domain: "test") == nil)
        precondition(reopened.password(address: "example.invalid:1445", username: "test-user", domain: "test") == nil)
        precondition(reopened.password(address: "example.invalid", username: "other", domain: "test") == nil)
        try store.save(server: server, username: "test-user", domain: "TEST", share: "Media", password: "changed")
        precondition(reopened.password(address: "example.invalid", username: "test-user", domain: "test") == "changed")
        try store.save(server: server, username: "", domain: "", share: "", password: "")
        precondition(reopened.password(address: "example.invalid", username: "guest", domain: "") == "")
        let profiles=defaults.dictionary(forKey:"serverProfiles.v1") as? [String:[String:String]]
        precondition(profiles?.count == 2)
        precondition(profiles?.values.allSatisfy { $0["password"] == nil } == true)
        let initialSelection = store.selected!.id
        let other = URL(string: "smb://other.invalid:1445")!
        try store.save(server: other, username: "alice", domain: "", share: "Movies", password: "alice-test",
                       id: "other-alice", name: "Archive", select: false)
        try store.save(server: other, username: "bob", domain: "", share: "Movies", password: "bob-test",
                       id: "other-bob", name: "Backup", select: false)
        precondition(store.connections.count == 4 && store.selected?.id == initialSelection)
        precondition(store.password(address: other.absoluteString, username: "alice", domain: "") == "alice-test")
        precondition(store.password(address: other.absoluteString, username: "bob", domain: "") == "bob-test")
        precondition(store.resolve(id: nil, server: other.absoluteString, share: "Movies") == nil, "Ambiguous legacy favorite must not guess an account")
        precondition(store.resolve(id: "missing", server: other.absoluteString, username: "alice") == nil)
        precondition(store.resolve(id: nil, server: other.absoluteString, username: "alice", domain: "", share: "Movies")?.id == "other-alice")
        let renamed = URL(string: "smb://renamed.invalid")!
        try store.save(server: renamed, username: "new-alice", domain: "WORK", share: "Movies", password: "new-test",
                       id: "other-alice", name: "Renamed Archive", select: false)
        precondition(store.connections.count == 4 && store.connection(id: "other-alice")?.server == renamed.absoluteString)
        precondition(store.resolve(id: "other-alice", server: other.absoluteString)?.username == "new-alice")
        var remote = store.connection(id: "other-bob")!.fields
        remote["name"] = "Cloud Backup"
        store.applySyncedProfile(id: "other-bob", fields: remote, updated: 200, deleted: false)
        store.reload()
        precondition(store.connection(id: "other-bob")?.name == "Cloud Backup")
        precondition(store.selected?.id == initialSelection, "A remote connection must not switch the local selection")
        let metadata = defaults.dictionary(forKey: "serverProfiles.v1") as! [String: [String: String]]
        precondition(metadata.count == 4 && metadata.values.allSatisfy { $0["password"] == nil })
        for address in ["https://nas.invalid", "smb://user:secret@nas.invalid", "smb://nas.invalid/Movies", "smb://nas.invalid?password=secret"] {
            precondition(ConnectionPreferences.serverURL(address) == nil)
        }
        let selectedBeforeDeletion = store.selected!.id
        store.delete(id: "other-alice")
        precondition(store.connections.count == 3 && store.connection(id: "other-alice") == nil)
        precondition(store.selected?.id == selectedBeforeDeletion, "Deleting another connection must preserve selection")
        store.delete(id: selectedBeforeDeletion)
        precondition(store.connections.count == 2 && store.selected?.id != selectedBeforeDeletion)
        precondition(defaults.string(forKey: "selectedConnectionID") == store.selected?.id)
        precondition(defaults.string(forKey: "server") == store.selected?.server)
        let remoteDeletion = store.selected!
        store.applySyncedProfile(id: remoteDeletion.id, fields: remoteDeletion.fields, updated: 400, deleted: true)
        precondition(store.connection(id: remoteDeletion.id) == nil && store.connections.count == 1)
        store.delete(id: "missing")
        precondition(store.connections.count == 1)
        // Multiple profiles may share an account/password; deleting one must not break the other.
        let remaining = store.selected!
        try store.save(server: URL(string: remaining.server)!, username: remaining.username, domain: remaining.domain,
                       share: "OtherShare", password: "shared-test", id: "shared-account", select: false)
        store.delete(id: remaining.id)
        precondition(store.selected?.id == "shared-account")
        precondition(store.password(address: remaining.server, username: remaining.username, domain: remaining.domain) == "shared-test")

        let migrationSuite = suite + ".migration"
        let legacy = UserDefaults(suiteName: migrationSuite)!
        defer { legacy.removePersistentDomain(forName: migrationSuite) }
        legacy.set("smb://old.invalid", forKey: "server")
        legacy.set("old-user", forKey: "username")
        legacy.set("Movies", forKey: "share")
        legacy.set(try JSONSerialization.data(withJSONObject: [["server": "smb://old.invalid", "share": "Movies", "path": "Folder"]]), forKey: "favoriteLocations.v1")
        legacy.set(["bookmark": ["server": "smb://old.invalid", "share": "Movies", "path": "Folder/movie.mkv", "username": "old-user", "domain": "", "size": "10"]], forKey: "playbackFiles.v1")
        legacy.set(["bookmark": ["seconds": 5.0, "duration": 10.0, "updated": 123.0]], forKey: "playbackPositions.v1")
        let migrated = ConnectionPreferences(defaults: legacy, service: suite)
        precondition(migrated.connections.count == 1)
        let migratedID = migrated.connections[0].id
        let favorite = (try JSONSerialization.jsonObject(with: legacy.data(forKey: "favoriteLocations.v1")!)) as! [[String: String]]
        precondition(favorite[0]["connectionID"] == migratedID)
        precondition(favorite[0]["identity"] == ["smb://old.invalid", "movies", "Folder"].joined(separator: "\0"))
        let files = legacy.dictionary(forKey: "playbackFiles.v1") as! [String: [String: String]]
        precondition(files["bookmark"]?["connectionID"] == migratedID)
        let progress = legacy.dictionary(forKey: "playbackPositions.v1") as! [String: [String: Double]]
        precondition(progress["bookmark"]?["updated"] == 123)
        var moved = migrated.connections[0].fields; moved["server"] = "smb://moved.invalid"
        migrated.applySyncedProfile(id: migratedID, fields: moved, updated: 300, deleted: false)
        let reopenedMigration = ConnectionPreferences(defaults: legacy, service: suite)
        precondition(reopenedMigration.connections.count == 1, "Legacy settings must not resurrect the previous address after editing")
        precondition(reopenedMigration.resolve(id: migratedID, server: "smb://old.invalid")?.server == "smb://moved.invalid")
        reopenedMigration.delete(id: migratedID)
        let afterDeletion = ConnectionPreferences(defaults: legacy, service: suite)
        precondition(afterDeletion.connections.isEmpty && afterDeletion.selected == nil)
        for key in ["selectedConnectionID", "server", "username", "domain", "share"] { precondition(legacy.object(forKey: key) == nil) }
        precondition(legacy.data(forKey: "favoriteLocations.v1") != nil)
        precondition((legacy.dictionary(forKey: "playbackFiles.v1") as? [String: [String: String]]) == files)
        precondition((legacy.dictionary(forKey: "playbackPositions.v1") as? [String: [String: Double]]) == progress)
        print("PASS: local/synced connection deletion, selection repair, shared credentials, preserved favorites/history and no resurrection after relaunch")
        print("PASS: multiple connections, isolated Keychain accounts, stable edits/cloud fields, local selection, ambiguous-account safety and idempotent legacy favorite/Watching migration")
    }
}
