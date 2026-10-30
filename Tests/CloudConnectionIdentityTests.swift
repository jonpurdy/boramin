import Foundation
import CryptoKit

@main struct CloudConnectionIdentityTests {
    static func recordID(_ profileID: String) -> String {
        SHA256.hash(data: Data(("server:" + profileID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func record(_ profileID: String, server: String, payloadID: String? = nil,
                       deleted: Bool = false, updated: Double = 100, user: String = "viewer", share: String = "Media") -> ICloudSync.Value {
        var fields = ["server": server, "username": user, "domain": "", "share": share]
        fields["id"] = payloadID ?? profileID
        if server.hasPrefix("https:") { fields["type"] = "http"; fields["share"] = "" }
        return .init(id: recordID(profileID), kind: "server", fields: fields,
            state: deleted ? "deleted" : "active", updated: Date(timeIntervalSince1970: updated), operation: "op-\(updated)")
    }
    @MainActor static func apply(_ value: ICloudSync.Value, to store: ConnectionPreferences, normalized: Bool = true) {
        let resolved = normalized ? ICloudSync.normalizedConnection(value)! : value
        store.applySyncedProfile(id: resolved.fields["id"]!, fields: resolved.fields,
            updated: resolved.updated.timeIntervalSince1970, deleted: resolved.state == "deleted")
        store.reload()
    }
    @MainActor static func main() throws {
        let server = URL(string: "smb://remote.example.invalid")!
        let legacyID = ConnectionPreferences.profileID(server: server, username: "viewer", domain: "")
        let uuid = "2364C00A-29F8-48E9-B3C2-962026062151"
        let otherID = "other-profile"
        let activeAlias = record(legacyID, server: server.absoluteString, payloadID: uuid)
        let deletion = record(uuid, server: server.absoluteString, deleted: true, updated: 200)
        let other = record(otherID, server: "smb://local.example.invalid")
        let validLegacy = record(legacyID, server: server.absoluteString)
        let suite = "BoraMin.CloudIdentityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionPreferences(defaults: defaults, service: suite)

        // Reproduce the observed failure using the old payload-ID rule.
        apply(activeAlias, to: store, normalized: false); apply(deletion, to: store, normalized: false)
        precondition(store.connections.isEmpty, "Old order should reproduce the missing connection")
        apply(deletion, to: store, normalized: false); apply(activeAlias, to: store, normalized: false)
        precondition(store.connection(id: uuid) != nil, "Reverse order should reproduce the resurrected profile")
        print("PASS: fixture reproduces the original missing/resurrected connection before normalization")

        let favorite = FavoriteLocation(server: server, share: "Media", path: "Folder", connectionID: legacyID, identity: "stable-favorite")!
        let favoriteData = try JSONEncoder().encode([favorite])
        defaults.set(favoriteData, forKey: "favoriteLocations.v1")
        let file = PlaybackFile(server: server, share: "Media", path: "Folder/video.mkv", size: 1234,
            username: "viewer", domain: "", connectionID: legacyID)!
        let positions = PlaybackPositions(defaults: defaults)
        positions.remember(file)
        positions.save(12, duration: 60, for: file.key, subtitle: .init(kind: .external, filename: "video.srt"))
        let fileData = defaults.dictionary(forKey: "playbackFiles.v1") as! [String: [String: String]]
        let subtitleData = defaults.dictionary(forKey: PlaybackPositions.subtitleStorageKey) as! [String: String]
        let progressData = defaults.dictionary(forKey: "playbackPositions.v1") as! [String: [String: Double]]

        for initial in [[], [validLegacy], [validLegacy, record(uuid, server: server.absoluteString)]] {
            for order in [[activeAlias, deletion, other], [deletion, other, activeAlias], [other, activeAlias, deletion], [other, deletion, activeAlias]] {
                defaults.set([String: [String: String]](), forKey: "serverProfiles.v1")
                store.reload()
                initial.forEach { apply($0, to: store) }
                // Repeat to verify idempotent application and simulated relaunch.
                for _ in 0..<3 {
                    order.forEach { apply($0, to: store) }
                    let reopened = ConnectionPreferences(defaults: defaults, service: suite)
                    precondition(Set(reopened.connections.map(\.id)) == Set([legacyID, otherID]))
                    precondition(reopened.connection(id: legacyID)?.server == server.absoluteString)
                }
            }
        }
        precondition(defaults.data(forKey: "favoriteLocations.v1") == favoriteData)
        precondition(defaults.dictionary(forKey: "playbackFiles.v1") as? [String: [String: String]] == fileData)
        precondition(defaults.dictionary(forKey: "playbackPositions.v1") as? [String: [String: Double]] == progressData)
        precondition(defaults.dictionary(forKey: PlaybackPositions.subtitleStorageKey) as? [String: String] == subtitleData)
        precondition(store.resolve(id: favorite.connectionID, server: favorite.server, share: favorite.share)?.id == legacyID)
        print("PASS: both conflict orders converge from missing/correct/duplicate profiles across repeated apply/relaunch, preserving favorite/Watching/subtitle identities")

        // Cache and outbox serialization must not turn metadata repair into a newer edit.
        var state = ICloudSync.State()
        state.items[activeAlias.id] = .init(value: activeAlias, systemFields: Data([1, 2, 3]))
        state.pending.insert(activeAlias.id)
        let restored = try JSONDecoder().decode(ICloudSync.State.self, from: JSONEncoder().encode(state))
        let cached = restored.items[activeAlias.id]!
        let normalized = ICloudSync.normalizedConnection(cached.value)!
        precondition(normalized.fields["id"] == legacyID && normalized.id == activeAlias.id)
        precondition(normalized.updated == activeAlias.updated && normalized.operation == activeAlias.operation)
        precondition(cached.systemFields == Data([1, 2, 3]) && restored.pending.contains(activeAlias.id))
        let pendingEdit = record(legacyID, server: "smb://edited.example.invalid", updated: 300)
        let outbox = try JSONDecoder().decode([String: ICloudSync.Value].self,
            from: JSONEncoder().encode([pendingEdit.id: pendingEdit]))
        precondition(ICloudSync.normalizedConnection(outbox[pendingEdit.id]!) == pendingEdit)
        precondition(pendingEdit.updated > normalized.updated, "Restoration must not age a pending local edit")
        print("PASS: cached and pending records retain record IDs, change tags, timestamps and operation ordering; edited legacy profiles keep their stable IDs")

        for value in [record(uuid, server: server.absoluteString), deletion,
                      record("another-account", server: server.absoluteString, user: "someone-else"),
                      record("another-share", server: server.absoluteString, share: "Other"),
                      record("http-profile", server: "https://remote.example.invalid/media/")] {
            precondition(ICloudSync.normalizedConnection(value) == value)
        }
        var noID = validLegacy; noID.fields.removeValue(forKey: "id")
        precondition(ICloudSync.normalizedConnection(noID)?.fields["id"] == legacyID)
        var invalid = activeAlias; invalid.id = recordID("unrelated-profile")
        precondition(ICloudSync.normalizedConnection(invalid) == nil, "Unverifiable payloads must not mutate a guessed profile")
        var wrongDelete = deletion; wrongDelete.fields["id"] = legacyID
        precondition(ICloudSync.normalizedConnection(wrongDelete) == nil, "An unverifiable deletion must not delete another profile")
        precondition(ICloudSync.normalizedConnection(other) == other)
        print("PASS: valid UUID, same-host account/share and HTTP identities stay distinct; unknown identities and cross-profile deletions are rejected")
    }
}
