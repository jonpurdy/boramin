// Offline regression for the extracted SMB boundary; no server or Keychain access.
import Foundation

@main @MainActor struct SMBBrowsingServiceTests {
    static func main() async throws {
        let date = Date(timeIntervalSince1970: 12345)
        let contents: [[URLResourceKey: Any]] = [
            [.nameKey: "z-folder", .fileResourceTypeKey: URLFileResourceType.directory],
            [.nameKey: "Episode 10.mkv", .fileResourceTypeKey: URLFileResourceType.regular, .fileSizeKey: NSNumber(value: 1024), .contentModificationDateKey: date],
            [.nameKey: ".hidden.mkv", .fileResourceTypeKey: URLFileResourceType.regular],
            [.fileSizeKey: NSNumber(value: 99)],
            [.nameKey: "Episode 2.mp4", .fileResourceTypeKey: URLFileResourceType.regular],
            [.nameKey: "notes.txt", .fileResourceTypeKey: URLFileResourceType.regular]
        ]
        let entries = SMBBrowsingService.entries(from: contents, path: "shows/Season 1")
        precondition(entries.map(\.name) == ["Episode 2.mp4", "Episode 10.mkv", "notes.txt", "z-folder"])
        precondition(entries[1].path == "shows/Season 1/Episode 10.mkv")
        precondition(entries[1].size == 1024 && entries[1].modified == 12345)
        precondition(entries[0].playable && !entries[2].playable && entries[3].directory)
        precondition(entries[0].size == 0 && entries[0].modified == 0)
        precondition(SMBBrowsingService.entries(from: [[.nameKey: "root.mkv"]], path: "").first?.path == "root.mkv")
        print("PASS: natural mixed folder/file order, dotfile filtering, paths, sizes, dates and media filtering inputs")

        func file(_ name: String, folder: String = "movies", directory: Bool = false) -> BrowserEntry {
            BrowserEntry(name: name, path: "\(folder)/\(name)", directory: directory, size: 10)
        }
        let video = file("Movie.mp4")
        try SMBBrowsingService.validateDeletion(expected: video,
            attributes: [.fileResourceTypeKey: URLFileResourceType.regular, .fileSizeKey: NSNumber(value: 10)])
        let changedItems: [[URLResourceKey: any Sendable]] = [
            [.fileResourceTypeKey: URLFileResourceType.regular, .fileSizeKey: NSNumber(value: 11)],
            [.fileResourceTypeKey: URLFileResourceType.directory, .fileSizeKey: NSNumber(value: 10)],
            [.fileResourceTypeKey: URLFileResourceType.symbolicLink, .fileSizeKey: NSNumber(value: 10)],
            [.fileResourceTypeKey: URLFileResourceType.regular]
        ]
        for attributes in changedItems {
            do {
                try SMBBrowsingService.validateDeletion(expected: video, attributes: attributes)
                preconditionFailure("Changed/non-regular file accepted for deletion")
            } catch is PlayerError { }
        }
        print("PASS: deletion accepts the expected regular file and rejects changed size, directories, symlinks and missing size")
        let sidecars = [file("Movie.srt"), file("Movie.ASS"), file("Movie.vtt"), file("Movie.ssa"),
                        file("Movie.en.srt"), file("Movie.eng.srt"), file("Movie.en-US.srt"), file("Movie.pt-BR.srt")]
        let unrelated = [file("Movie.commentary.srt"), file("Other.srt"), file("movie.srt"),
                         file("Movie.srt", folder: "elsewhere"), file("Movie.ass", directory: true)]
        let planned = SMBBrowsingService.associatedSubtitles(for: video, in: [video] + sidecars + unrelated)
        precondition(planned.map(\.path) == sidecars.map(\.path))
        for sibling in [file("Movie.mkv"), file("MOVIE.MOV")] {
            precondition(SMBBrowsingService.associatedSubtitles(for: video, in: [video, sibling] + sidecars).isEmpty)
        }
        precondition(SMBBrowsingService.associatedSubtitles(for: file("Movie.txt"), in: sidecars).isEmpty)
        print("PASS: exact subtitle matching, all supported extensions, folder boundaries and shared-video protection")

        for (suffix, tag) in [("en", "en"), ("eng", "en"), ("EN-us", "en-US"), ("pt-BR", "pt-BR"), ("zh-Hans-CN", "zh-Hans-CN"), ("es-419", "es-419")] {
            let match = ExternalSubtitleFiles.match(videoName: video.name, subtitleName: "Movie.\(suffix).SRT")
            precondition(match?.languageTag == tag && match?.ext == "srt")
        }
        for suffix in ["zz", "zzz", "en-QQ", "en-Qwer", "en-US-extra", "en.forced", "en.sdh", "en_US", "en--US", "en-US\n", "", "commentary"] {
            precondition(!ExternalSubtitleFiles.matches(videoName: video.name, subtitleName: "Movie.\(suffix).srt"))
        }
        precondition(!ExternalSubtitleFiles.matches(videoName: video.name, subtitleName: "Movie2.en.srt"))
        let english = ExternalSubtitleFiles.match(videoName: video.name, subtitleName: "Movie.eng.srt")!
        precondition(english.menuName(locale: Locale(identifier: "en")) == "English — SRT — External")
        let sharedLanguageFile = file("Movie.en.srt")
        let protected = SMBBrowsingService.associatedSubtitles(for: video, in: [video, file("Movie.en.mkv"), file("Movie.srt"), sharedLanguageFile])
        precondition(protected.map(\.name) == ["Movie.srt"])
        print("PASS: validated language/script/region tags, localized labels, malformed tag rejection and overlapping subtitle ownership")

        let removal = DeletionRecorder(failing: [sidecars[0].path])
        let result = try await SMBBrowsingService.executeDeletion(path: video.path, subtitles: sidecars) {
            try await removal.remove($0)
        }
        let attempts = await removal.attempts
        precondition(attempts == [video.path] + sidecars.map(\.path))
        precondition(result.removedPaths == [video.path] + sidecars.dropFirst().map(\.path))
        precondition(result.failedSubtitleNames == [sidecars[0].name])
        let denied = DeletionRecorder(failing: [video.path])
        do {
            _ = try await SMBBrowsingService.executeDeletion(path: video.path, subtitles: sidecars) {
                try await denied.remove($0)
            }
            preconditionFailure("Video deletion should fail")
        } catch is PlayerError { }
        let deniedAttempts = await denied.attempts
        precondition(deniedAttempts == [video.path])
        print("PASS: video-first deletion, partial subtitle failure accounting, and no subtitle deletion after video failure")

        let client = try SMBBrowsingService.makeClient(server: " nas.local ", username: "", domain: "", password: "", timeout: 5)
        precondition(client.url.absoluteString == "smb://nas.local" && client.timeout == 5)
        for address in ["", "https://nas.local", "smb://user:password@nas.local", "smb://nas.local/share"] {
            do {
                _ = try SMBBrowsingService.makeClient(server: address, username: "", domain: "", password: "")
                preconditionFailure("Invalid server accepted")
            } catch is PlayerError { }
        }
        print("PASS: server normalization and rejection of credentials, share paths and unsupported schemes")

        let flag = CancellationFlag(); flag.cancel()
        let cancelled = await MetadataProbeService.inspect(session: RemoteSession(smb: client), path: "unused.mkv", size: 1, fileExtension: "mkv", cancellation: flag)
        precondition(cancelled.0 == nil && cancelled.1 == nil)
        print("PASS: cancelled metadata probe returns without opening a remote file")
    }
}

private actor DeletionRecorder {
    let failing: Set<String>
    private(set) var attempts: [String] = []
    init(failing: Set<String>) { self.failing = failing }
    func remove(_ path: String) throws {
        attempts.append(path)
        if failing.contains(path) { throw PlayerError("Deletion denied") }
    }
}
