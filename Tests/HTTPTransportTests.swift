import AppKit
import AVKit

@main @MainActor struct HTTPTransportTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw PlayerError(message) }
    }
    static func expectFailure(_ message: String, _ action: () async throws -> Void) async throws {
        do { try await action() } catch { return }
        throw PlayerError("Unexpected success: " + message)
    }
    static func wait(_ label: String, timeout: Double = 20, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw PlayerError("Timed out: " + label) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let base = URL(string: CommandLine.arguments[1]), let faults = URL(string: CommandLine.arguments[2]) else {
            throw PlayerError("Pass the isolated Caddy and fault-server URLs.")
        }
        // Status failures must precede content/range validation and retain their codes.
        for status in [401, 403, 404, 503] {
            let response = HTTPURLResponse(url: base, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Encoding": "gzip"])!
            for policy in [HTTPReadPolicy.listing, .range(0..<1, size: 1, etag: nil, modified: nil)] {
                do { try policy.validate(response); throw PlayerError("HTTP status accepted") }
                catch let error as HTTPStatusError { try check(error.statusCode == status, "HTTP status lost") }
            }
        }
        print("PASS: HTTP statuses preserved before listing, encoding and byte-range validation")
        let service = HTTPFileService(baseURL: base, username: "", password: "")
        defer { service.close() }
        let rows = try await service.readDirectory(path: "")
        try check(rows.map(\.name) == ["big.bin", "Engines", "Folder", "Movie #1% 日本.mp4", "Movie #1% 日本.srt"], "Caddy listing/filter/order mismatch")
        let children = try await service.readDirectory(path: "Folder")
        try check(children.first?.path == "Folder/child.txt", "Nested directory path mismatch")
        let video = rows.first { $0.name.hasSuffix(".mp4") }!
        try check(video.size > 0 && video.modified > 0, "Caddy size/modification metadata missing")
        do { _ = try service.url(path: "../outside"); throw PlayerError("Traversal accepted") }
        catch let error as PlayerError { try check(error.message != "Traversal accepted", "Traversal accepted") }
        let escapedURL = try service.url(path: video.path)
        try check(escapedURL.absoluteString.contains("%23"), "Filename was not URL escaped")
        print("PASS: actual Caddy JSON, nested directories, metadata, sorting, hidden files and escaped filenames")

        let source = try await service.openFile(path: "big.bin", size: 140 * 1024 * 1024, cancellation: CancellationFlag())
        try await Task.detached {
            for block in 0..<560 {
                let bytes = try source.read(offset: Int64(block * 256 * 1024), count: 8)
                guard bytes.count == 8, bytes.withUnsafeBytes({ $0.loadUnaligned(as: UInt64.self).littleEndian }) == UInt64(block) else { throw PlayerError("Random-access bytes mismatch") }
                guard source.transferMetrics.cached <= source.transferMetrics.capacity else { throw PlayerError("Cache budget exceeded") }
            }
            let before = source.fetchedBytes
            _ = try source.read(offset: Int64(559 * 256 * 1024), count: 8)
            guard source.fetchedBytes == before else { throw PlayerError("Cached bytes were fetched again") }
            _ = try source.read(offset: 0, count: 8)
            guard source.fetchedBytes > before, source.transferMetrics.capacity == 128 * 1024 * 1024 else { throw PlayerError("Cache eviction/capacity mismatch") }
        }.value
        print("PASS: HTTP byte identity, forward/backward reads, cache hits, eviction and 128 MiB bound")

        // Real Caddy Basic authentication; no credentials are read from user defaults.
        let authBase = base.deletingLastPathComponent().appendingPathComponent("auth", isDirectory: true)
        let authenticated = HTTPFileService(baseURL: authBase, username: "fixture", password: "test-only")
        _ = try await authenticated.readDirectory(path: "")
        authenticated.close()
        let unauthenticated = HTTPFileService(baseURL: authBase, username: "", password: "")
        await tryFailure(unauthenticated) // Unauthorized listing must not appear as an empty directory.
        print("PASS: Caddy Basic authentication and unauthorized errors")

        for (mode, username, password) in [
            ("credentials-anonymous", "", ""), ("credentials-username", "fixture", ""),
            ("credentials-password", "", "test-only"), ("credentials-both", "fixture", "test-only")
        ] {
            let optional = HTTPFileService(baseURL: faults.appendingPathComponent(mode, isDirectory: true), username: username, password: password)
            _ = try await optional.readDirectory(path: "")
            let file = try await optional.openFile(path: "movie.bin", size: 1024 * 1024, cancellation: CancellationFlag())
            let bytes = try await Task.detached { try file.read(offset: 0, count: 8) }.value
            try check(bytes.count == 8, "Optional credentials failed for listing/range reads")
            optional.close()
        }
        print("PASS: anonymous, username-only, password-only and paired HTTP credentials for JSON listings and byte ranges")

        for mode in ["ignored", "wrong-range", "wrong-length", "truncated", "changed", "encoded", "outside", "cross-origin", "unsatisfiable", "oversized"] {
            let bad = HTTPFileService(baseURL: faults.appendingPathComponent(mode, isDirectory: true), username: "fixture", password: "test-only")
            try await expectFailure(mode) {
                let file = try await bad.openFile(path: "movie.bin", size: 1024 * 1024, cancellation: CancellationFlag())
                _ = try await Task.detached { try file.read(offset: 0, count: 256) }.value
            }
            bad.close()
        }
        for mode in ["html", "large-listing", "bad-json", "bad-name"] {
            let bad = HTTPFileService(baseURL: faults.appendingPathComponent(mode, isDirectory: true), username: "", password: "")
            try await expectFailure(mode) { _ = try await bad.readDirectory(path: "") }
            bad.close()
        }
        let slow = HTTPFileService(baseURL: faults.appendingPathComponent("slow", isDirectory: true), username: "", password: "")
        let loading = Task { try await slow.readDirectory(path: "") }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = Date(); loading.cancel()
        do { _ = try await loading.value; throw PlayerError("Cancelled request succeeded") } catch is CancellationError { }
        try check(Date().timeIntervalSince(cancelledAt) < 1, "HTTP cancellation was not prompt")
        slow.close()
        let slowReads = HTTPFileService(baseURL: faults.appendingPathComponent("slow-read", isDirectory: true), username: "", password: "")
        let fileFlag = CancellationFlag(), readFlag = CancellationFlag()
        let interruptible = try await slowReads.openFile(path: "movie.bin", size: 1024 * 1024, cancellation: fileFlag)
        let reading = Task.detached { try interruptible.read(offset: 0, count: 10, interrupt: readFlag) }
        try await Task.sleep(for: .milliseconds(100))
        let readCancelledAt = Date(); readFlag.cancel()
        do { _ = try await reading.value; throw PlayerError("Cancelled byte read succeeded") } catch is CancellationError { }
        try check(Date().timeIntervalSince(readCancelledAt) < 1 && !fileFlag.cancelled, "A per-reader cancellation closed the whole source")
        let retry = try await Task.detached { try interruptible.read(offset: 0, count: 10) }.value
        try check(retry.count == 10, "Independent reader could not continue after cancellation")
        slowReads.close()
        let slowProbe = HTTPFileService(baseURL: faults.appendingPathComponent("slow-probe", isDirectory: true), username: "", password: "")
        let probeFlag = CancellationFlag()
        let probing = Task { try await slowProbe.openFile(path: "movie.bin", size: 1024 * 1024, cancellation: probeFlag) }
        try await Task.sleep(for: .milliseconds(100))
        let probeCancelledAt = Date(); probeFlag.cancel()
        do { _ = try await probing.value; throw PlayerError("Cancelled header probe succeeded") } catch is CancellationError { }
        try check(Date().timeIntervalSince(probeCancelledAt) < 1, "Flag cancellation did not stop the HTTP header probe")
        slowProbe.close()
        let nginxJSON = Data("[{\"name\":\"Folder\",\"type\":\"directory\"},{\"name\":\"movie.mp4\",\"type\":\"file\",\"size\":123}]".utf8)
        let nginxEntries = try HTTPFileService.entries(data: nginxJSON, path: "")
        try check(nginxEntries.count == 2 && nginxEntries[0].directory && nginxEntries[1].size == 123, "nginx JSON mapping failed")
        var transient: RemoteSession? = try RemoteSession.make(server: base.absoluteString, username: "", domain: "", password: "")
        let retainedFile = try await transient!.openFile(path: video.path, size: video.size, cancellation: CancellationFlag())
        transient = nil
        let retainedBytes = try await Task.detached { try retainedFile.read(offset: 0, count: 8) }.value
        try check(retainedBytes.count == 8, "A remote file did not retain its HTTP transport")
        print("PASS: ignored/malformed/truncated/changed/oversized ranges, encoded responses, redirects, bad listings, cancellation and independent-reader lifetime")

        let suite = "BoraMin.HTTPTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ConnectionPreferences(defaults: defaults, service: suite)
        profiles.applySyncedProfile(id: "http-fixture", fields: ["server": base.absoluteString, "type": "http"], updated: 123, deleted: false)
        profiles.reload()
        let saved = profiles.connection(id: "http-fixture")!
        let browser = Browser(connections: profiles, metadataCache: MediaMetadataCache(defaults: defaults))
        profiles.applySyncedProfile(id: "slow-fixture", fields: ["server": faults.appendingPathComponent("slow", isDirectory: true).absoluteString, "type": "http"], updated: 123, deleted: false)
        profiles.reload()
        browser.openConnection(profiles.connection(id: "slow-fixture")!)
        try await Task.sleep(for: .milliseconds(100))
        browser.cancel()
        try check(!browser.busy && browser.playing == nil, "HTTP browser Cancel did not clear the operation")
        browser.openConnection(saved)
        try await wait("browser directory") { !browser.busy }
        try check(browser.connected && !browser.isShareListing && !browser.canDeleteFiles && browser.entries.count == rows.count, "HTTP browser root mismatch")
        browser.openDirectory("Folder")
        try await wait("browser child") { !browser.busy }
        try check(browser.path == "Folder" && browser.entries.count == 1, "HTTP directory navigation failed")
        browser.back()
        try await wait("browser parent") { !browser.busy }
        let favorite = browser.favoriteLocation(path: "Folder")!
        let favoriteBrowser = Browser(connections: profiles, metadataCache: MediaMetadataCache(defaults: defaults))
        var opened = false
        favoriteBrowser.openFavorite(favorite) { opened = true }
        try await wait("favorite reopen") { !favoriteBrowser.busy }
        try check(opened && favoriteBrowser.path == "Folder", "HTTP favorite reopen failed")
        favoriteBrowser.disconnect()
        let subtitles = await ExternalSubtitles.discover(session: RemoteSession(http: service), path: video.path, playbackCancellation: CancellationFlag())
        try check(subtitles?.tracks.count == 1, "External subtitle discovery failed")
        if let track = subtitles?.tracks.first {
            let data = try await track.load(CancellationFlag())
            try check(String(data: data, encoding: .utf8)?.contains("HTTP subtitle fixture") == true, "External subtitle bytes mismatch")
        }
        let savedFavorites = Favorites(defaults: defaults)
        savedFavorites.add(favorite)
        try check(Favorites(defaults: defaults).locations.first == favorite, "HTTP favorite persistence failed")
        let history = PlaybackPositions(defaults: defaults)
        let file = PlaybackFile(server: base, share: "", path: video.path, size: video.size, username: "", domain: "", connectionID: saved.id)!
        history.remember(file); history.save(3, duration: 8, for: file.key, subtitle: SavedSubtitleSelection(kind: .external, filename: "Movie #1% 日本.srt"))
        try check(history.watching().first?.file == file && history.subtitleSelection(for: file.key)?.filename == "Movie #1% 日本.srt", "HTTP Watching/resume/subtitle persistence failed")
        let watchingBrowser = Browser(connections: profiles, metadataCache: MediaMetadataCache(defaults: defaults))
        watchingBrowser.openWatching(file)
        try await wait("Watching reopen") { !watchingBrowser.busy }
        try check(watchingBrowser.playing?.positionKey == file.key, "HTTP Watching reopen failed")
        watchingBrowser.playbackEnded(); watchingBrowser.disconnect()
        print("PASS: HTTP browser root/parent/favorites, Watching persistence/reopen and matching external subtitle discovery/loading")

        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let flag = CancellationFlag()
        let session = try RemoteSession.make(server: base.absoluteString, username: "", domain: "", password: "")
        let media = try await PreparedMedia.stream(session: session, path: video.path, size: video.size,
            title: "HTTP fixture", directory: Browser.cache, cancellation: flag)
        defer { media.streaming?.stop(); session.abort(); browser.disconnect() }
        MacPlaybackWindow.present(media: media) { }
        guard let controller = MacPlaybackWindow.current, let view = controller.window?.contentView as? MacPlayerView,
              let player = view.player, let item = player.currentItem else { throw PlayerError("No HTTP playback window") }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output)
        try await wait("HTTP video pixels") { player.currentTime().seconds > 0.3 && output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil }
        for target in [5.0, 1.0] {
            guard await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) else { throw PlayerError("HTTP seek failed") }
            try await wait("HTTP pixels after seek") { player.currentTime().seconds > target + 0.1 && output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil }
        }
        player.pause(); let paused = player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(200))
        try check(abs(player.currentTime().seconds - paused) < 0.1, "HTTP pause did not hold")
        controller.window?.close()
        print("PASS: actual Mac AVPlayer HTTP video pixels, forward/backward seeking, pause and teardown")
        for entry in try await service.readDirectory(path: "Engines") {
            let engineMedia = try await PreparedMedia.stream(session: session, path: entry.path, size: entry.size,
                title: "HTTP engine fixture", directory: Browser.cache, cancellation: CancellationFlag())
            MacPlaybackWindow.present(media: engineMedia) { }
            if let backend = engineMedia.streaming?.aetherPlayback, backend.player == nil {
                try await wait("HTTP Aether software renders") { hasRenderedVideo(MacSoftwarePlaybackWindow.current?.window?.contentView) && backend.engine.currentTime > 0.2 }
                for target in [5.0, 1.0] {
                    await backend.engine.seek(to: target)
                    try await wait("HTTP Aether software seek") { backend.engine.currentTime >= target && backend.engine.currentTime < target + 2 && hasRenderedVideo(MacSoftwarePlaybackWindow.current?.window?.contentView) }
                }
                MacSoftwarePlaybackWindow.current?.close()
                print("PASS: HTTP Aether software video rendering and seeks")
            } else {
                guard let window = MacPlaybackWindow.current, let nativeView = window.window?.contentView as? MacPlayerView,
                      let player = nativeView.player, let item = player.currentItem else { throw PlayerError("No HTTP engine playback window") }
                let pixels = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                if !engineMedia.usesSampleBufferVideo { item.add(pixels) }
                try await wait("HTTP engine renders") {
                    if engineMedia.usesSampleBufferVideo { return nativeView.sampleVideo?.layer.status == .rendering && (nativeView.sampleVideo?.queuedTime ?? -1) > 0.2 }
                    return player.currentTime().seconds > 0.2 && pixels.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil
                }
                for target in [5.0, 1.0] {
                    guard await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) else { throw PlayerError("HTTP engine seek failed") }
                    try await wait("HTTP engine renders after seek") {
                        guard player.currentTime().seconds > target + 0.1, player.currentTime().seconds < target + 2 else { return false }
                        if engineMedia.usesSampleBufferVideo { return nativeView.sampleVideo?.layer.status == .rendering && (nativeView.sampleVideo?.queuedTime ?? -1) >= target }
                        return pixels.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil
                    }
                }
                window.close()
                print("PASS: HTTP \(engineMedia.usesSampleBufferVideo ? "original VP9" : "Aether native") video output and seeks")
            }
            engineMedia.streaming?.stop()
        }
        print("PASS: HTTP transport integration")
    }
    static func hasRenderedVideo(_ view: NSView?) -> Bool {
        func rendered(_ layer: CALayer) -> Bool {
            if let display = layer as? AVSampleBufferDisplayLayer, display.status == .rendering { return true }
            return (layer.sublayers ?? []).contains(where: rendered)
        }
        guard let view else { return false }
        return (view.layer.map(rendered) ?? false) || view.subviews.contains { hasRenderedVideo($0) }
    }
    static func tryFailure(_ service: HTTPFileService) async {
        do { _ = try await service.readDirectory(path: ""); fatalError("Unauthorized listing accepted") } catch { }
        service.close()
    }
}
