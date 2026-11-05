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
        precondition(store.password(connectionID: nil) == nil)
        let server = URL(string: "smb://example.invalid")!
        try store.save(server: server, username: "test-user", domain: "TEST", share: "Media", password: " synthetic password \n", id: "primary")
        let reopened = ConnectionPreferences(defaults: UserDefaults(suiteName: suite)!, service: suite)
        precondition(reopened.password(connectionID: "primary") == " synthetic password \n")
        precondition(defaults.string(forKey: "server") == server.absoluteString)
        precondition(defaults.string(forKey: "share") == "Media")
        precondition(defaults.string(forKey: "password") == nil)
        precondition(reopened.password(connectionID: "missing") == nil)
        try store.save(server: server, username: "test-user", domain: "TEST", share: "Media", password: "changed", id: "primary")
        precondition(reopened.password(connectionID: "primary") == "changed")
        try store.save(server: server, username: "", domain: "", share: "", password: "", id: "guest")
        precondition(reopened.password(connectionID: "guest") == "")
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
        precondition(store.password(connectionID: "other-alice") == "alice-test")
        precondition(store.password(connectionID: "other-bob") == "bob-test")
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
        // Separate shares on the same account must retain independent credentials.
        let remaining = store.selected!
        try store.save(server: URL(string: remaining.server)!, username: remaining.username, domain: remaining.domain,
                       share: "OtherShare", password: "shared-test", id: "shared-account", select: false)
        precondition(store.password(connectionID: remaining.id) == "changed")
        precondition(store.password(connectionID: "shared-account") == "shared-test")
        store.delete(id: remaining.id)
        precondition(store.password(connectionID: remaining.id) == nil)
        precondition(store.selected?.id == "shared-account")
        precondition(store.password(connectionID: "shared-account") == "shared-test")

        precondition(ConnectionScheme.smb.url(address: "nas.local", port: 445)?.absoluteString == "smb://nas.local")
        precondition(ConnectionScheme.http.url(address: "nas.local/Videos/", port: 80)?.absoluteString == "http://nas.local/Videos/")
        precondition(ConnectionScheme.https.url(address: "[2001:db8::1]/Videos%20HD/", port: 8443)?.absoluteString
            == "https://[2001:db8::1]:8443/Videos%20HD/")
        for address in ["https://nas.local/Videos/", "nas.local:8443/Videos/", "user@nas.local", "nas.local/?token=test"] {
            precondition(ConnectionScheme.https.url(address: address, port: 443) == nil)
        }
        precondition(ConnectionScheme.smb.url(address: "nas.local", port: 65536) == nil)

        let httpRoot = ConnectionPreferences.connectionURL("HTTPS://EXAMPLE.invalid:443/Media")!
        precondition(httpRoot.absoluteString == "https://example.invalid/Media/")
        precondition(ConnectionPreferences.connectionURL("http://example.invalid:80/")!.absoluteString == "http://example.invalid/")
        for invalid in ["https://user:password@example.invalid/", "https://example.invalid/?token=x", "https://example.invalid/#x", "https://example.invalid/media/../", "ftp://example.invalid/"] {
            precondition(ConnectionPreferences.connectionURL(invalid) == nil)
        }
        let legacySMBFields = store.connection(id: "shared-account")!.fields
        try store.save(server: httpRoot, username: "test-user", domain: "", share: "", password: "http-test",
                       id: "http-test", select: false, kind: .http)
        precondition(store.connection(id: "http-test")?.kind == .http)
        precondition(store.connection(id: "http-test")?.fields["type"] == "http")
        precondition(store.password(connectionID: "http-test") == "http-test")
        precondition(store.connection(id: "shared-account")!.fields == legacySMBFields)
        precondition(legacySMBFields["type"] == nil, "Legacy SMB cloud payload must stay unchanged")
        do {
            try store.save(server: server, username: "test-user", domain: "", share: "", password: "unused", id: "http-test")
            preconditionFailure("Editing changed the saved connection type")
        } catch { }
        for (index, pair) in [("", ""), ("fixture", ""), ("", "test-only"), ("fixture", "test-only")].enumerated() {
            let root = URL(string: "https://example.invalid/optional-\(index)/")!
            try store.save(server: root, username: pair.0, domain: "", share: "", password: pair.1, id: "optional-\(index)", select: false, kind: .http)
            precondition(store.connection(id: "optional-\(index)")?.username == pair.0)
            precondition(store.password(connectionID: "optional-\(index)") == pair.1)
        }
        print("PASS: both HTTP credential fields are independently optional and persist through Keychain")
        let httpFields = store.connection(id: "http-test")!.fields
        store.applySyncedProfile(id: "http-copy", fields: httpFields, updated: 500, deleted: false)
        store.reload()
        precondition(store.connection(id: "http-copy")?.server == httpRoot.absoluteString)
        precondition(store.password(connectionID: "http-copy") == nil, "A synced profile must not borrow another connection's password")
        try store.storePassword(connectionID: "http-copy", password: "http-copy-test")
        precondition(store.password(connectionID: "http-test") == "http-test")
        precondition(store.password(connectionID: "http-copy") == "http-copy-test")
        store.delete(id: "http-copy")
        precondition(store.password(connectionID: "http-copy") == nil)
        precondition(store.password(connectionID: "http-test") == "http-test")
        precondition(store.connection(id: "shared-account")!.fields == legacySMBFields)
        precondition(SavedConnection(id: "unknown", fields: ["server": httpRoot.absoluteString]) == nil)
        print("PASS: HTTP roots, isolated Keychain credentials, fixed connection types and additive cloud profiles preserve SMB data")

        let credentialSuite = suite + ".credential-migration"
        let credentialDefaults = UserDefaults(suiteName: credentialSuite)!
        defer { credentialDefaults.removePersistentDomain(forName: credentialSuite) }
        var legacyProfiles: [String: [String: String]] = [:]
        for (url, user, domain, kind, ids, password) in [
            (server, "legacy-user", "", "smb", ["smb-a", "smb-b"], "legacy-smb-test"),
            (httpRoot, "legacy-user", "", "http", ["http-a", "http-b"], "legacy-http-test")
        ] {
            let account = Data(ConnectionPreferences.credentialIdentity(server: url, username: user, domain: domain).joined(separator: "\0").utf8).base64EncodedString()
            precondition(SecItemAdd([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: suite, kSecAttrAccount as String: account,
                kSecValueData as String: Data(password.utf8)] as CFDictionary, nil) == errSecSuccess)
            for id in ids {
                var fields = ["server": url.absoluteString, "username": user, "domain": domain, "share": "Media"]
                if kind == "http" { fields["type"] = "http" }
                legacyProfiles[id] = fields
            }
        }
        credentialDefaults.set(legacyProfiles, forKey: "serverProfiles.v1")
        let migratedCredentials = ConnectionPreferences(defaults: credentialDefaults, service: suite)
        precondition(migratedCredentials.password(connectionID: "smb-a") == "legacy-smb-test")
        precondition(migratedCredentials.password(connectionID: "smb-b") == "legacy-smb-test")
        precondition(migratedCredentials.password(connectionID: "http-a") == "legacy-http-test")
        precondition(migratedCredentials.password(connectionID: "http-b") == "legacy-http-test")
        try migratedCredentials.storePassword(connectionID: "smb-b", password: "new-smb-test")
        try migratedCredentials.storePassword(connectionID: "http-b", password: "")
        let migrationReopen = ConnectionPreferences(defaults: credentialDefaults, service: suite)
        precondition(migrationReopen.password(connectionID: "smb-a") == "legacy-smb-test")
        precondition(migrationReopen.password(connectionID: "smb-b") == "new-smb-test")
        precondition(migrationReopen.password(connectionID: "http-a") == "legacy-http-test")
        precondition(migrationReopen.password(connectionID: "http-b") == "")
        try migrationReopen.save(server: server, username: "legacy-user", domain: "", share: "First", password: "first-test", select: false)
        let firstAdded = migrationReopen.connections.first { $0.share == "First" }!
        try migrationReopen.save(server: server, username: "legacy-user", domain: "", share: "Second", password: "second-test", select: false)
        let secondAdded = migrationReopen.connections.first { $0.share == "Second" }!
        precondition(firstAdded.id != secondAdded.id)
        precondition(migrationReopen.password(connectionID: firstAdded.id) == "first-test")
        precondition(migrationReopen.password(connectionID: secondAdded.id) == "second-test")
        precondition(migrationReopen.password(connectionID: "smb-a") == "legacy-smb-test")
        print("PASS: legacy SMB/HTTP credentials migrate per ID once and remain independent after edits and relaunch")

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
        print("PASS: local/synced connection deletion, selection repair, independent credentials, preserved favorites/history and no resurrection after relaunch")
        print("PASS: multiple connections, isolated Keychain accounts, stable edits/cloud fields, local selection, ambiguous-account safety and idempotent legacy favorite/Watching migration")
    }
}
