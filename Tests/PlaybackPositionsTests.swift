import Foundation

@main struct PlaybackPositionsTests {
    @MainActor static func main() {
        let suite = "BoraMin.PositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPositions(defaults: defaults)
        let server = URL(string: "smb://NAS.local")!
        let key = PlaybackPositions.key(server: server, share: "Movies", path: "Folder/movie.mkv", size: 1234)
        precondition(key == PlaybackPositions.key(server: URL(string: "smb://user:secret@nas.local:445")!, share: "movies", path: "Folder/movie.mkv", size: 1234))
        precondition(key != PlaybackPositions.key(server: URL(string: "smb://other.local")!, share: "Movies", path: "Folder/movie.mkv", size: 1234))
        precondition(key != PlaybackPositions.key(server: URL(string: "smb://nas.local:1445")!, share: "Movies", path: "Folder/movie.mkv", size: 1234))
        precondition(key != PlaybackPositions.key(server: server, share: "Other", path: "Folder/movie.mkv", size: 1234))
        precondition(key != PlaybackPositions.key(server: server, share: "Movies", path: "Other/movie.mkv", size: 1234))
        precondition(key != PlaybackPositions.key(server: server, share: "Movies", path: "Folder/movie.mkv", size: 4321))
        precondition(store.position(for: key, duration: 1000) == nil)
        store.save(765, duration: 956.25, for: key)
        let reopened = PlaybackPositions(defaults: UserDefaults(suiteName: suite)!)
        precondition(reopened.position(for: key, duration: 956.25) == 765)
        precondition(reopened.progress(for: key)?.prefix == "(80%, 00:12:45)")
        precondition(reopened.allProgress()[key]?.prefix == "(80%, 00:12:45)")
        store.save(.nan, duration: 956.25, for: key)
        store.save(-10, duration: 956.25, for: key)
        precondition(store.position(for: key, duration: 956.25) == 765)
        precondition(store.position(for: key, duration: 600) == nil)
        store.save(955.9, duration: 956.25, for: key)
        precondition(store.progress(for: key)?.prefix == "(99%, 00:15:55)")
        store.clear(key)
        precondition(reopened.progress(for: key) == nil)
        precondition((defaults.dictionary(forKey:"playbackResets.v1")?[key] as? Double) != nil)
        store.save(20, duration: 100, for: key)
        precondition(defaults.dictionary(forKey:"playbackResets.v1")?[key] == nil)
        store.save(100, duration: 100, for: key)
        precondition(store.progress(for: key) == nil)
        let file = PlaybackFile(server: URL(string: "smb://user:secret@NAS.local:445")!, share: "Movies",
                                path: "Folder/movie.mkv", size: 1234, username: "viewer", domain: "HOME")!
        store.remember(file)
        precondition(file.key == key && file.server == "smb://nas.local")
        precondition(!file.fields.values.contains(where: { $0.contains("secret") }))
        precondition(file.fields["openedAt"] == nil)
        store.save(20, duration: 100, for: key)
        let another = PlaybackFile(server: server, share: "Movies", path: "Other/other.mkv", size: 5678, username: "viewer", domain: "HOME")!
        store.remember(another)
        store.save(30, duration: 100, for: another.key)
        var records = defaults.dictionary(forKey: "playbackPositions.v1") as! [String: [String: Double]]
        records[key]!["updated"] = 100
        records[another.key]!["updated"] = 200
        defaults.set(records, forKey: "playbackPositions.v1")
        precondition(reopened.watching().map(\.id) == [another.key, key])
        precondition(reopened.watching().last?.file?.name == "movie.mkv")
        // Metadata recovery must not change the existing last-save order or progress.
        store.remember(file)
        precondition(reopened.watching().last?.lastSaved == 100)
        precondition(reopened.position(for: key, duration: 100) == 20)
        // Legacy bookmarks remain visible even before their filename is recovered.
        store.forgetFile(key)
        precondition(reopened.watching().last?.file == nil)
        store.remember(file)
        store.clear(another.key)
        precondition(reopened.watching().map(\.id) == [key])
        store.save(100, duration: 100, for: key)
        precondition(reopened.watching().isEmpty)

        for index in 0..<505 { store.save(Double(index + 1), duration: 1000, for: "file\(index)") }
        precondition((defaults.dictionary(forKey: "playbackPositions.v1")?.count ?? 0) == 500)
        precondition(store.progress(for: "file504") != nil)
        print("PASS: persistent bookmarks, Watching metadata and last-save order, legacy recovery without timestamp changes, reset/completion removal and bounded storage")
    }
}
