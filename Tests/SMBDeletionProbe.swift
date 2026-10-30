// Disposable local Samba fixture only. Never points at a user's media server.
import Foundation

@main @MainActor struct SMBDeletionProbe {
    static func wait(_ browser: Browser) async throws {
        for _ in 0..<400 {
            if !browser.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PlayerError("Delete probe timed out")
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw PlayerError("Pass the disposable Samba fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let name = "delete-probe-" + UUID().uuidString
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let manager = try SMBBrowsingService.makeClient(server: "smb://127.0.0.1:1445", username: "boramin-test", domain: "", password: "test-only", timeout: 5)
        try await SMBBrowsingService.connectShare(manager, name: "TESTMEDIA")
        let local = folder.appendingPathComponent("delete me.mp4")
        try Data("disposable".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: local.path)
        let path = name + "/delete me.mp4"
        _ = try await SMBBrowsingService.attributes(manager, path: path)
        try await SMBBrowsingService.removeFile(manager, path: path)
        let remains = FileManager.default.fileExists(atPath: local.path)
        print("DELETE callback returned success; backing file remains=\(remains)")
        precondition(!remains)
        do {
            _ = try await SMBBrowsingService.attributes(manager, path: path)
            preconditionFailure("Deleted file still exists on SMB")
        } catch let error as NSError {
            precondition(error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        }
        print("PASS: successful SMB deletion removes the actual backing file")

        let suite = "BoraMinDeleteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = Browser(connections: ConnectionPreferences(defaults: defaults), metadataCache: MediaMetadataCache(defaults: defaults))
        browser.client = manager; browser.connected = true; browser.share = "TESTMEDIA"; browser.path = name
        try Data("disposable".utf8).write(to: local)
        let entry = BrowserEntry(name: "delete me.mp4", path: path, directory: false, size: 10)
        browser.entries = [entry]
        browser.deleteFile(entry)
        try await wait(browser)
        precondition(browser.error == nil && browser.entries.isEmpty && !FileManager.default.fileExists(atPath: local.path))
        print("PASS: file-browser deletion removes the backing file before hiding the row")

        try Data("disposable".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        browser.entries = [entry]
        browser.deleteFile(entry)
        try await wait(browser)
        precondition(browser.error != nil && browser.entries.count == 1 && FileManager.default.fileExists(atPath: local.path))
        print("PASS: permission-denied deletion preserves the file and list row, and reports an error")
        await SMBBrowsingService.disconnect(manager)
    }
}
