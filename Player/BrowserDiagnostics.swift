import Foundation
import AMSMB2

// Opt-in CLI diagnostics. Normal browsing never invokes these operations.
@MainActor extension Browser {
    static var diagnosticPlaybackHistoryEnabled: Bool { !CommandLine.arguments.contains("--no-playback-history") }
    static func reportDiagnosticPlaybackEnded() {
        if CommandLine.arguments.contains("--exercise-mkv-controls") { print("BORAMIN_MKV_TEST returned to browser") }
    }
    static func reportDiagnosticFailure(_ failure: NSError) {
        if CommandLine.arguments.contains("--aether-diagnostics") {
            print("BORAMIN_DIAGNOSTICS operation failed domain=\(failure.domain) code=\(failure.code)"); fflush(stdout)
        }
    }

    func runSmokeTestIfRequested() {
        if let index = CommandLine.arguments.firstIndex(of: "--test-connection-id"), CommandLine.arguments.count > index + 1,
           let saved = connections.connection(id: CommandLine.arguments[index + 1]) {
            connectionID = saved.id; host = saved.server; username = saved.username; domain = saved.domain
            password = connections.password(address: saved.server, username: saved.username, domain: saved.domain) ?? ""
        }
        if CommandLine.arguments.contains("--aether-diagnostics") {
            print("BORAMIN_DIAGNOSTICS smokeRequested=\(CommandLine.arguments.contains("--stream-smoke-test")) busy=\(busy)"); fflush(stdout)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--stream-smoke-test"), CommandLine.arguments.count > index + 2 {
            let testShare = CommandLine.arguments[index + 1], testPath = CommandLine.arguments[index + 2]
            perform("Opening test share…") { [self] in
                let manager = try SMBBrowsingService.makeClient(server: host, username: username, domain: domain, password: password, timeout: 15)
                client = manager
                try await SMBBrowsingService.connectShare(manager, name: testShare)
                if CommandLine.arguments.contains("--aether-diagnostics") { print("BORAMIN_DIAGNOSTICS share connected"); fflush(stdout) }
                let attributes = try await SMBBrowsingService.attributes(manager, path: testPath)
                let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                if CommandLine.arguments.contains("--aether-diagnostics") { print("BORAMIN_DIAGNOSTICS file size=\(size)"); fflush(stdout) }
                let entry = BrowserEntry(name: (testPath as NSString).lastPathComponent, path: testPath, directory: false, size: size)
                try Task.checkCancellation()
                let folder = (testPath as NSString).deletingLastPathComponent
                let contents = try await readDirectory(folder, shareName: testShare)
                try Task.checkCancellation()
                connected = true; share = testShare; path = folder; entries = contents
                let flag = cancellation
                Task { @MainActor in
                    guard !flag.cancelled else { return }
                    if CommandLine.arguments.contains("--exercise-player-lifecycle") {
                        await self.exercisePlayerLifecycle(entry)
                    } else { self.play(entry) }
                }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--smb-smoke-test"), CommandLine.arguments.count > index + 1 {
            let address = CommandLine.arguments[index + 1]
            perform("Connecting to isolated SMB test share…") { [self] in
                let manager = try SMBBrowsingService.makeClient(server: address, username: "guest", domain: "", password: "", timeout: 15)
                client = manager
                let names = try await SMBBrowsingService.listShares(manager)
                guard names.contains("TESTMEDIA") else { throw PlayerError("Test share not enumerated.") }
                print("BORAMIN_SMB shares enumerated: \(names.count)")
                try await SMBBrowsingService.connectShare(manager, name: "TESTMEDIA")
                let root = try await readDirectory("")
                guard root.contains(where: { $0.directory && $0.name == "Nested" }) else { throw PlayerError("Test folder missing.") }
                let files = try await readDirectory("Nested")
                guard let entry = files.first(where: { $0.playable }) else { throw PlayerError("Test video missing.") }
                print("BORAMIN_SMB browsed nested folder; video size \(entry.size)")
                try Task.checkCancellation()
                connected = true; share = "TESTMEDIA"; path = "Nested"; entries = files
                let flag = cancellation
                Task { @MainActor in if !flag.cancelled { self.play(entry) } }
            }
            return
        }
        let nativeTracks = CommandLine.arguments.contains("--native-tracks-smoke-test")
        guard nativeTracks || CommandLine.arguments.contains("--smoke-test") else { return }
        perform("Preparing device smoke test…") { [self] in
            let source = nativeTracks ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("native-tracks.mp4") :
                Bundle.main.url(forResource: "smoke", withExtension: "webm") ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("smoke.webm")
            let directory = Self.cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let flag = cancellation
            let media = try await Task.detached {
                try PreparedMedia.prepare(source: source, directory: directory, title: "Media playback smoke test", cancellation: flag)
            }.value
            if flag.cancelled || Task.isCancelled {
                media.streaming?.stop(); try? FileManager.default.removeItem(at: directory)
                throw CancellationError()
            }
            playbackDirectory = directory; playing = media
        }
    }
    func exercisePlayerLifecycle(_ entry: BrowserEntry) async {
        var frames = Set<UUID>()
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("BoraMinProbeFrame"), object: nil, queue: .main) { note in
            if let id = note.object as? UUID { frames.insert(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            for cycle in 1...3 {
                try Task.checkCancellation()
                var next = entry
                if cycle == 2, let index = CommandLine.arguments.firstIndex(of: "--test-second-video"), CommandLine.arguments.count > index + 1, let client {
                    let path = CommandLine.arguments[index + 1]
                    let attributes = try await SMBBrowsingService.attributes(client, path: path)
                    next = BrowserEntry(name: (path as NSString).lastPathComponent, path: path, directory: false,
                                        size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
                }
                play(next)
                for _ in 0..<300 {
                    if playing != nil || error != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let media = playing else { throw PlayerError(error ?? "Lifecycle test could not open video.") }
                print("BORAMIN_LIFECYCLE opened cycle=\(cycle) id=\(media.id)")
                if CommandLine.arguments.contains("--probe-frames-only") {
                    for _ in 0..<600 {
                        if frames.contains(media.id) || error != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard frames.contains(media.id) else { throw PlayerError("No confirmed video in lifecycle cycle \(cycle).") }
                    try await Task.sleep(for: .seconds(3))
                } else { try await Task.sleep(for: .seconds(10)) }
                guard playing?.id == media.id else { throw PlayerError("Playback was dismissed during the lifecycle test.") }
                playing = nil
                for _ in 0..<100 {
                    if activeStream == nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard activeStream == nil else { throw PlayerError("Previous player did not dismiss.") }
                if let key = media.positionKey {
                    guard let progress = PlaybackPositions.shared.progress(for: key),
                          entries.first(where: { $0.path == entry.path })?.displayName.hasPrefix("(") == true else {
                        throw PlayerError("Playback position or file-list prefix was not saved.")
                    }
                    print("BORAMIN_LIFECYCLE bookmark cycle=\(cycle) prefix=\(progress.prefix)")
                }
                print("BORAMIN_LIFECYCLE dismissed cycle=\(cycle)")
                try await Task.sleep(for: .milliseconds(500))
            }
            print("BORAMIN_LIFECYCLE PASS: three open/play/dismiss cycles in one process")
        } catch { print("BORAMIN_LIFECYCLE FAILED: \(error.localizedDescription)") }
    }

}
