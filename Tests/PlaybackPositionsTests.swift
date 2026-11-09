import Foundation

private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    var subtitleWrites = 0
    override func set(_ value: Any?, forKey key: String) {
        if key == "playbackSubtitles.v1" { subtitleWrites += 1 }
        super.set(value, forKey: key)
    }
}

@main struct PlaybackPositionsTests {
    @MainActor static func main() {
        let suite = "BoraMin.PositionTests.\(UUID().uuidString)"
        let defaults = CountingDefaults(suiteName: suite)!
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
        store.save(20, duration: 100, for: key)
        precondition(reopened.watching().map(\.id) == [another.key, key])
        precondition(reopened.watching().last?.lastSaved == 100)
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

        let subtitle = SavedSubtitleSelection(kind: .external, filename: "movie.ass")
        let unchangedKey = "unchanged-checkpoint"
        store.save(40, duration: 100, for: unchangedKey, subtitle: subtitle)
        var checkpointRecords = defaults.dictionary(forKey: "playbackPositions.v1") as! [String: [String: Double]]
        checkpointRecords[unchangedKey]!["updated"] = 1
        defaults.set(checkpointRecords, forKey: "playbackPositions.v1")
        let before = defaults.persistentDomain(forName: suite)!
        store.save(40, duration: 100, for: unchangedKey)
        store.save(40, duration: 100, for: unchangedKey, subtitle: subtitle)
        precondition((before as NSDictionary).isEqual(to: defaults.persistentDomain(forName: suite)!))
        precondition(store.subtitleSelection(for: unchangedKey) == subtitle)
        store.save(41, duration: 100, for: unchangedKey)
        precondition(store.progress(for: unchangedKey)?.seconds == 41)
        store.save(41, duration: 110, for: unchangedKey)
        precondition(store.progress(for: unchangedKey)?.duration == 110)
        let explicitOff = SavedSubtitleSelection(kind: .off)
        store.save(41, duration: 110, for: unchangedKey, subtitle: explicitOff)
        precondition(store.subtitleSelection(for: unchangedKey) == explicitOff)
        defaults.set([unchangedKey: 2.0], forKey: "playbackResets.v1")
        store.save(41, duration: 110, for: unchangedKey, subtitle: explicitOff)
        precondition(defaults.dictionary(forKey: "playbackResets.v1")?[unchangedKey] == nil)
        store.clear(unchangedKey)
        print("PASS: unchanged checkpoints preserve stored state and Watching order; changed position/duration/subtitles and reset markers still persist")
        store.saveSubtitle(subtitle, for: key)
        precondition(store.subtitleSelection(for: key) == nil && store.progress(for: key) == nil)
        store.save(20, duration: 100, for: key, subtitle: subtitle)
        precondition(reopened.subtitleSelection(for: key) == subtitle)
        store.save(25, duration: 100, for: key)
        precondition(reopened.subtitleSelection(for: key) == subtitle)
        let audio = SavedTrackSelection(kind: .engine, stream: 2, name: "Commentary", codec: "aac")
        store.saveAudio(audio, for: "no-position")
        precondition(store.progress(for: "no-position") == nil)
        store.saveAudio(audio, for: key)
        store.save(26, duration: 100, for: key)
        precondition(reopened.audioSelection(for: key) == audio)
        precondition(reopened.subtitleSelection(for: key) == subtitle)
        let off = SavedSubtitleSelection(kind: .off)
        store.saveSubtitle(off, for: key)
        precondition(reopened.subtitleSelection(for: key) == off)
        store.clear(key)
        precondition(defaults.dictionary(forKey: PlaybackPositions.subtitleStorageKey)?[key] == nil)
        precondition(defaults.dictionary(forKey: PlaybackPositions.audioStorageKey)?[key] == nil)
        store.save(20, duration: 100, for: key, subtitle: subtitle)
        store.save(100, duration: 100, for: key)
        precondition(store.subtitleSelection(for: key) == nil)
        // Simulate the optional field on an incoming encrypted position payload.
        store.save(30, duration: 100, for: key)
        let recordTime = store.watching().first!.lastSaved
        store.applySyncedSubtitle(subtitle.encoded, for: key)
        precondition(store.subtitleSelection(for: key) == subtitle && store.watching().first!.lastSaved == recordTime)
        let writes = defaults.subtitleWrites
        precondition(writes > 0)
        store.applySyncedSubtitle(subtitle.encoded, for: key)
        precondition(defaults.subtitleWrites == writes, "An identical cloud subtitle must not generate another preference write")
        store.applySyncedSubtitle(nil, for: key) // Legacy client / no subtitle choice.
        precondition(defaults.subtitleWrites == writes + 1, "Removing a cloud subtitle must still persist")
        precondition(store.subtitleSelection(for: key) == nil)
        store.applySyncedSubtitle("invalid JSON", for: key)
        precondition(store.subtitleSelection(for: key) == nil)
        store.clear(key)
        store.applySyncedSubtitle(subtitle.encoded, for: key)
        precondition(store.subtitleSelection(for: key) == nil && store.progress(for: key) == nil)
        store.save(1, duration: 100, for: "old-subtitle", subtitle: subtitle)

        let httpRoot = URL(string: "https://nas.local/media/")!
        let httpFile = PlaybackFile(server: httpRoot, share: "", path: "Folder/movie.mkv", size: 1234, username: "viewer", domain: "", connectionID: "http")!
        precondition(httpFile.key != key)
        for root in ["http://nas.local/media/", "https://nas.local/Media/", "https://nas.local/other/"] {
            precondition(httpFile.key != PlaybackPositions.key(server: URL(string: root)!, share: "", path: httpFile.path, size: httpFile.size))
        }
        store.remember(httpFile); store.save(20, duration: 100, for: httpFile.key)
        precondition(reopened.watching().contains { $0.file == httpFile })
        precondition(PlaybackFile(fields: httpFile.fields) == httpFile)
        store.clear(httpFile.key)
        print("PASS: HTTP Watching identities preserve scheme/base path/case and coexist with unchanged SMB keys")
        for index in 0..<505 { store.save(Double(index + 1), duration: 1000, for: "file\(index)") }
        precondition((defaults.dictionary(forKey: "playbackPositions.v1")?.count ?? 0) == 500)
        precondition(store.progress(for: "file504") != nil)
        precondition(defaults.dictionary(forKey: PlaybackPositions.subtitleStorageKey)?.isEmpty == true)
        print("PASS: subtitle identity persistence, no orphan selections, Off, cloud-field apply/legacy compatibility, reset/completion cleanup and eviction")
        print("PASS: persistent bookmarks, Watching metadata and last-save order, legacy recovery without timestamp changes, reset/completion removal and bounded storage")
    }
}
