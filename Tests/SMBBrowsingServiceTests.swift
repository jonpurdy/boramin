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
