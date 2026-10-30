// Read-only live-server regression. Connection metadata comes from an ignored local fixture;
// passwords are read from existing Keychain entries, never printed or copied into preferences.
import AppKit
import Foundation
import Darwin

@main @MainActor struct ConnectionOpeningProbe {
    static func waitForConnection(_ browser: Browser) async throws {
        let deadline = Date().addingTimeInterval(30)
        while browser.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard browser.connected, browser.connectionError == nil, !browser.shares.isEmpty else {
            throw PlayerError("Connection probe did not reach its share list.")
        }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        guard (2...4).contains(CommandLine.arguments.count) else { throw PlayerError("Pass a local connection metadata plist.") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let profiles = saved["serverProfiles.v1"] as! [String: [String: String]]
        let suite = "BoraMinConnectionOpeningProbe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(profiles, forKey: "serverProfiles.v1")
        let store = ConnectionPreferences(defaults: defaults)
        let cache = MediaMetadataCache(defaults: defaults)
        let browser = Browser(connections: store, metadataCache: cache)
        guard store.connections.count >= 2 else { throw PlayerError("Probe needs two saved servers.") }
        let cycles = CommandLine.arguments.contains("--stress") ? 10 : 1
        for cycle in 0..<cycles {
        for connection in store.connections {
            browser.openConnection(connection)
            try await waitForConnection(browser)
            guard browser.connectionID == connection.id else { throw PlayerError("Wrong connection opened.") }
            if CommandLine.arguments.contains("--browse"),
               let name = browser.shares.first(where: { !$0.hasSuffix("$") }) {
                browser.openShare(name)
                try await waitForConnection(browser)
                let names = browser.entries.map(\.name)
                guard browser.share == name, browser.path.isEmpty,
                      names.allSatisfy({ !$0.hasPrefix(".") }),
                      names == names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }),
                      let favorite = browser.favoriteLocation(path: ""), favorite.connectionID == connection.id else {
                    throw PlayerError("Directory listing or favorite identity changed.")
                }
                var opened = false
                browser.openFavorite(favorite) { opened = true }
                try await waitForConnection(browser)
                guard opened, browser.entries.map(\.name) == names, browser.share == name, browser.path.isEmpty else {
                    throw PlayerError("Favorite did not reopen the same directory.")
                }
                browser.back()
                try await waitForConnection(browser)
                guard browser.share.isEmpty else { throw PlayerError("Parent navigation did not return to shares.") }
                print("PASS: directory filtering/order, favorite connection identity and parent navigation")
            }
            browser.disconnect()
            // Reproduce an awaiting SwiftUI task being cancelled while its screen changes.
            let screen = Task { await browser.automaticallyConnect() }
            screen.cancel()
            await screen.value
            try await waitForConnection(browser)
            browser.showConnections()
            guard browser.showingConnections, !browser.connected else { throw PlayerError("Back did not return to connections.") }
        }
        print("PASS connection cycle \(cycle + 1)")
        }
        if CommandLine.arguments.contains("--watching") {
            let files = saved["playbackFiles.v1"] as? [String: [String: String]] ?? [:]
            let active = saved["playbackPositions.v1"] as? [String: [String: Double]] ?? [:]
            let candidates = files.filter { active[$0.key] != nil }.sorted { $0.key < $1.key }
            guard let file = candidates.compactMap({ PlaybackFile(fields: $0.value) }).first else { throw PlayerError("No active Watching fixture.") }
            let key = MediaMetadataCache.key(server: URL(string: file.server)!, connectionID: file.connectionID, share: file.share, path: file.path, size: file.size)
            await browser.loadWatchingMetadata(file)
            guard let record = cache.value(for: key) else { throw PlayerError("Watching metadata probe did not discover a route.") }
            await browser.loadWatchingMetadata(file)
            guard cache.value(for: key)?.stored == record.stored else { throw PlayerError("Watching metadata did not reuse the cache.") }
            print("PASS: uncached Watching file discovers a playback route and reuses its local cache")
        }
        print("PASS: both saved servers open, enumerate shares, reconnect after screen-task cancellation, switch and return to Connections")
    }
}
