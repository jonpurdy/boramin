// Read-only real-file diagnostic. Uses isolated preferences and existing Keychain credentials.
import AppKit
import AVFoundation
import AVKit
import AetherEngine
import Darwin

private final class ProbeFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    func record(_ frame: SoftwareVideoFrameTime) {
        lock.lock(); defer { lock.unlock() }
        samples.append(frame.presentation.seconds)
        if samples.count > 120 { samples.removeFirst() }
    }
    func reset() { lock.lock(); samples.removeAll(); lock.unlock() }
    var span: (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        guard samples.count >= 12, let first = samples.first, let last = samples.last else { return nil }
        return (first, last)
    }
}

@main @MainActor struct PlaybackFailureProbe {
    static func controls(_ engine: AetherEngine) async throws {
        engine.pause()
        try await Task.sleep(for: .milliseconds(300))
        let paused = engine.currentTime
        try await Task.sleep(for: .milliseconds(500))
        guard abs(engine.currentTime - paused) < 0.1 else { throw PlayerError("Paused clock advanced") }
        let frames = ProbeFrames()
        engine.setSoftwareVideoFrameTimeObserver { frames.record($0) }
        for target in [60.0, 5.0] {
            await engine.seek(to: target)
            frames.reset()
            engine.play()
            var passed = false
            for _ in 0..<200 {
                if let span = frames.span, span.0 >= target - 1, span.1 > span.0 + 0.4,
                   engine.currentTime >= target + 0.5, abs(engine.currentTime - span.1) < 2 {
                    print("PASS seek target=\(target) clock=\(engine.currentTime) frames=\(span)")
                    passed = true; break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard passed else { throw PlayerError("Seek did not produce fresh video near the clock") }
            engine.pause()
        }
        engine.setSoftwareVideoFrameTimeObserver(nil)
        engine.stop()
        print("PASS pause, forward/backward seek, and stop")
    }
    static func errors(_ error: Error?) {
        var next = error as NSError?
        for _ in 0..<5 {
            guard let current = next else { break }
            print("ERROR domain=\(current.domain) code=\(current.code)")
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
    }
    private struct LiveCheckError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private struct FixtureConfiguration: Decodable {
        struct Fixture: Decodable {
            let folder: String
            let file: String
            let subtitle: String?
            let role: String?
        }

        let smbConnectionID: String
        let httpConnectionID: String
        let smbShare: String
        let fixtureRoot: String
        let fixtures: [Fixture]
        let diagnostics: [String: String]

        static func load() throws -> Self {
            let path = ProcessInfo.processInfo.environment["BORAMIN_PLAYBACK_FIXTURES"]
                ?? "Config/PlaybackFixtures.local.json"
            guard let data = FileManager.default.contents(atPath: path) else {
                throw PlayerError("Copy Config/PlaybackFixtures.example.json to Config/PlaybackFixtures.local.json and configure your fixtures.")
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }
    }

    private static func livePlayback(config: FixtureConfiguration) async throws {
        let preferenceURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/\(BoraMinIdentity.appBundleIdentifier)/Data/Library/Preferences/\(BoraMinIdentity.appBundleIdentifier).plist")
        let saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferenceURL), format: nil)
        guard let profiles = (saved as? [String: Any])?["serverProfiles.v1"] as? [String: [String: String]] else {
            throw LiveCheckError("Saved BoraMin profiles unavailable.")
        }
        let suite = "BoraMinLivePlayback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(profiles, forKey: "serverProfiles.v1")
        defaults.set(true, forKey: "connectionCredentialsMigrated.v2")
        let connections = ConnectionPreferences(defaults: defaults)
        let transports: [(String, String, ConnectionKind)] = [
            ("SMB", config.smbConnectionID, .smb),
            ("HTTP", config.httpConnectionID, .http),
        ]
        let fixtures = config.fixtures
        var failures = 0
        for (label, id, kind) in transports {
            do {
                guard let profile = connections.connection(id: id), profile.kind == kind else {
                    throw LiveCheckError("Expected saved connection unavailable.")
                }
                let session = try RemoteSession.make(server: profile.server, username: profile.username,
                    domain: profile.domain, password: connections.password(connectionID: id) ?? "")
                defer { session.abort() }
                if kind == .smb { try await session.connectShare(name: config.smbShare) }
                let folders = Set(fixtures.map(\.folder))
                var base = config.fixtureRoot
                if kind == .http {
                    let rootFolders = Set(try await session.readDirectory(path: "").filter(\.directory).map(\.name))
                    let fixtureFolder = (config.fixtureRoot as NSString).lastPathComponent
                    if rootFolders.contains(fixtureFolder) {
                        base = fixtureFolder
                    } else if !rootFolders.isDisjoint(with: folders) {
                        base = ""
                    }
                }
                let prefix = base.isEmpty ? "" : base + "/"
                let expected = Set(fixtures.flatMap { fixture in
                    [fixture.file, fixture.subtitle].compactMap { $0 }.map { "\(fixture.folder)/\($0)" }
                })
                var actual = Set<String>()
                for entry in try await session.readDirectory(path: base) where !entry.name.hasPrefix(".") {
                    if entry.directory {
                        for child in try await session.readDirectory(path: prefix + entry.name) where !child.name.hasPrefix(".") && (child.directory || child.size > 0) {
                            actual.insert("\(entry.name)/\(child.name)" + (child.directory ? "/" : ""))
                        }
                    } else if entry.size > 0 {
                        actual.insert(entry.name)
                    }
                }
                if actual != expected {
                    print("FAIL \(label) inventory missing=\(expected.subtracting(actual).sorted()) unexpected=\(actual.subtracting(expected).sorted())")
                    failures += 1
                }
                for fixture in fixtures {
                    let path = "\(prefix)\(fixture.folder)/\(fixture.file)"
                    print("START \(label) \(fixture.file)")
                    do {
                        let route = try await verifyLiveFile(session, path: path, subtitle: fixture.subtitle,
                            hardwareVP9: fixture.role == "hardwareVP9",
                            checkASS: kind == .smb && fixture.role == "ass",
                            checkAudio: kind == .smb && fixture.role == "audio")
                        print("PASS \(label) \(fixture.file) [\(route)]")
                    } catch {
                        print("FAIL \(label) \(fixture.file)")
                        if let error = error as? LiveCheckError { print("CHECK \(error.message)") }
                        errors(error)
                        failures += 1
                    }
                }
            } catch {
                print("INCOMPLETE \(label) fixture access")
                errors(error)
                failures += 1
            }
        }
        guard failures == 0 else { throw LiveCheckError("Live playback suite has \(failures) failed or incomplete checks.") }
    }

    static func verifyLiveFile(_ session: RemoteSession, path: String, subtitle: String?, hardwareVP9: Bool,
                               checkASS: Bool, checkAudio: Bool) async throws -> String {
        let entry = try await session.attributes(path: path)
        let media = try await PreparedMedia.stream(session: session, path: path, size: entry.size,
            title: entry.name, directory: Browser.cache, cancellation: CancellationFlag())
        defer {
            MacPlaybackWindow.current?.close()
            MacSoftwarePlaybackWindow.current?.close()
            media.streaming?.stop()
        }
        var subtitleTrackID: String?
        if let subtitle {
            guard let track = media.streaming?.externalSubtitles?.tracks.first(where: {
                ($0.id as NSString).lastPathComponent == subtitle
            }), try await !track.load(CancellationFlag()).isEmpty else {
                throw LiveCheckError("Expected external subtitle is missing or empty.")
            }
            subtitleTrackID = track.id
        }
        if hardwareVP9, (!media.usesSampleBufferVideo || media.info.vp9 == 0) {
            throw LiveCheckError("Expected dedicated VP9 hardware playback.")
        }
        MacPlaybackWindow.present(media: media) { }
        let frames = ProbeFrames()
        let engine = media.streaming?.aetherPlayback?.engine
        engine?.setSoftwareVideoFrameTimeObserver { frames.record($0) }
        defer { engine?.setSoftwareVideoFrameTimeObserver(nil) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        var attachedItem: AVPlayerItem?
        func displayedBuffer(in layer: CALayer) -> CVPixelBuffer? {
            if let layer = layer as? AVSampleBufferDisplayLayer {
                return layer.sampleBufferRenderer.displayedPixelBuffer()
            }
            return layer.sublayers?.lazy.compactMap { displayedBuffer(in: $0) }.first
        }
        func displayedBuffer(in view: NSView) -> CVPixelBuffer? {
            view.layer.flatMap { displayedBuffer(in: $0) }
                ?? view.subviews.lazy.compactMap { displayedBuffer(in: $0) }.first
        }
        func verifyFrames(after target: Double) async throws {
            var firstFrame: Double?
            var firstPixel: CVPixelBuffer?
            frames.reset()
            for _ in 0..<300 {
                if MacSoftwarePlaybackWindow.current != nil {
                    if let span = frames.span, span.0 >= target - 1, span.1 < target + 5,
                       span.1 > span.0 + 0.25,
                       let view = MacSoftwarePlaybackWindow.current?.window?.contentView,
                       let pixel = displayedBuffer(in: view) {
                        if let firstPixel, firstPixel !== pixel { return }
                        firstPixel = pixel
                    }
                } else if let controller = MacPlaybackWindow.current,
                          let player = (controller.window?.contentView as? MacPlayerView)?.player,
                          let item = player.currentItem {
                    let time = player.currentTime()
                    var frame: Double?
                    var pixel: CVPixelBuffer?
                    if let video = controller.sampleVideo {
                        if let displayed = video.layer.sampleBufferRenderer.displayedPixelBuffer(),
                           abs(video.queuedTime - time.seconds) < 1 {
                            pixel = displayed
                            frame = video.queuedTime
                        }
                    } else if !hardwareVP9 {
                        if attachedItem !== item {
                            attachedItem?.remove(output)
                            item.add(output)
                            attachedItem = item
                        }
                        var displayedTime = CMTime.invalid
                        if let displayed = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayedTime) {
                            pixel = displayed
                            frame = displayedTime.seconds
                        }
                    }
                    if let pixel, let frame, frame >= target - 0.25, frame < target + 5 {
                        if let firstFrame, let firstPixel, frame > firstFrame + 0.25, firstPixel !== pixel { return }
                        if firstFrame == nil {
                            firstFrame = frame
                            firstPixel = pixel
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw LiveCheckError("Advancing video frames were not observed near \(target)s.")
        }
        try await verifyFrames(after: 0)
        if checkAudio {
            guard let tracks = MacPlaybackWindow.current?.tracks else {
                throw LiveCheckError("fixture audio controls unavailable.")
            }
            for _ in 0..<100 {
                if tracks.audio.contains(where: { $0.supported && $0.id != tracks.selectedAudio }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let alternate = tracks.audio.first(where: { $0.supported && $0.id != tracks.selectedAudio }) else {
                throw LiveCheckError("No alternate supported fixture audio track.")
            }
            tracks.selectAudio(alternate.id)
            for _ in 0..<100 {
                if engine?.activeAudioTrackIndex == alternate.id { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard engine?.activeAudioTrackIndex == alternate.id else { throw LiveCheckError("Audio selection did not take effect.") }
        }
        let targets = [min(60, media.info.duration / 2), 3.0]
        if MacSoftwarePlaybackWindow.current != nil, let engine {
            guard !hardwareVP9 else { throw LiveCheckError("Expected dedicated VP9 hardware playback.") }
            engine.togglePlayPause()
            // Allow the software clock to publish its final position after the pause request.
            // Require a continuous stationary interval before accepting the pause.
            var paused = engine.currentTime
            var stableSamples = 0
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                let time = engine.currentTime
                if engine.state == .paused, abs(time - paused) < 0.05 {
                    stableSamples += 1
                    if stableSamples == 4 { break }
                } else {
                    stableSamples = 0
                    paused = time
                }
            }
            guard stableSamples == 4 else { throw LiveCheckError("Pause did not hold.") }
            engine.togglePlayPause()
            try await verifyFrames(after: paused)
            for target in targets {
                await engine.seek(to: target)
                engine.play()
                try await verifyFrames(after: target)
            }
        } else if let player = (MacPlaybackWindow.current?.window?.contentView as? MacPlayerView)?.player {
            if checkASS, let subtitles = media.streaming?.externalSubtitles, let subtitleTrackID {
                subtitles.select("external:" + subtitleTrackID)
                for _ in 0..<100 {
                    if subtitles.ready { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                player.pause()
                guard await player.seek(to: CMTime(seconds: 1.5, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero) else {
                    throw LiveCheckError("Seek to ASS cue failed.")
                }
                for _ in 0..<100 {
                    if subtitles.frame != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard subtitles.frame != nil else { throw LiveCheckError("ASS cue did not produce a subtitle bitmap.") }
            }
            player.pause()
            let paused = player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(400))
            guard abs(player.currentTime().seconds - paused) < 0.15 else { throw LiveCheckError("Pause did not hold.") }
            player.play()
            try await verifyFrames(after: paused)
            for target in targets {
                guard await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero) else {
                    throw LiveCheckError("Seek failed.")
                }
                try await verifyFrames(after: target)
            }
        } else {
            throw LiveCheckError("Playback window closed before controls could be exercised.")
        }
        if hardwareVP9 { return "VideoToolbox hardware VP9" }
        if MacSoftwarePlaybackWindow.current != nil { return "AetherEngine software route" }
        return engine == nil ? "AVPlayer" : "AetherEngine native route"
    }

    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let mode = CommandLine.arguments.dropFirst().first ?? "blade"
        let config: FixtureConfiguration
        do { config = try FixtureConfiguration.load() }
        catch {
            print("INCOMPLETE playback fixture configuration: \(error.localizedDescription)")
            exit(1)
        }
        if mode == "live" {
            do { try await livePlayback(config: config) }
            catch { errors(error); exit(1) }
            return
        }
        guard let relativePath = config.diagnostics[mode] else { throw PlayerError("Unknown playback diagnostic mode.") }
        let path = config.fixtureRoot.isEmpty ? relativePath : config.fixtureRoot + "/" + relativePath
        let pref = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(BoraMinIdentity.appBundleIdentifier)/Data/Library/Preferences/\(BoraMinIdentity.appBundleIdentifier).plist")
        let saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: pref), format: nil) as! [String: Any]
        let suite = "BoraMinPlaybackFailureProbe-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved["serverProfiles.v1"], forKey: "serverProfiles.v1")
        let store = ConnectionPreferences(defaults: defaults)
        var media: PreparedMedia?
        for connection in store.connections {
            guard connection.id == config.smbConnectionID, connection.kind == .smb else { continue }
            let browser = Browser(connections: store, metadataCache: MediaMetadataCache(defaults: defaults))
            guard let url = URL(string: connection.server) else { continue }
            let client = AMSMB2.SMB2Manager(url: url, domain: connection.domain, credential: URLCredential(user: connection.username.isEmpty ? "guest" : connection.username, password: store.password(connectionID: connection.id) ?? "", persistence: .none))!
            client.timeout = 8
            do {
                try await client.connectShare(name: config.smbShare)
                let attrs = try await client.attributesOfItem(atPath: path), size = (attrs[.fileSizeKey] as! NSNumber).int64Value
                if CommandLine.arguments.contains("--packet-timing") {
                    let source = CachedRemoteFile(client: client, path: path, size: size, cancellation: CancellationFlag())
                    var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
                    guard let reader = media_open_io(source.makeIO(), &info, &error, error.count) else { throw PlayerError("Packet timing open failed") }
                    defer { media_close(reader) }
                    for index in 0..<30 {
                        var bytes: UnsafePointer<UInt8>?, count: Int32 = 0, key: Int32 = 0
                        var pts = 0.0, duration = 0.0
                        guard media_packet(reader, &bytes, &count, &pts, &duration, &key) > 0 else { break }
                        print("SOURCE_VIDEO_PACKET index=\(index) pts=\(pts) duration=\(duration) key=\(key)")
                    }
                    return
                }
                EngineLog.handler = { print($0) }
                if CommandLine.arguments.contains("--documented-host") {
                    // Minimal upstream integration: bind before load, engine-owned display criteria.
                    let engine = try AetherEngine()
                    let surface = AetherPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
                    let window = NSWindow(contentRect: surface.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.contentView = surface
                    engine.bind(view: surface)
                    window.orderFrontRegardless()
                    defer { engine.stop(); window.close() }
                    let source = CachedRemoteFile(client: client, path: path, size: size, cancellation: CancellationFlag())
                    var options = LoadOptions()
                    options.autoplay = false
                    options.preferredDecodePath = .software
                    try await engine.load(source: .custom(AetherFileReader(source: source), formatHint: "matroska"), options: options)
                    let started = ProcessInfo.processInfo.systemUptime
                    engine.play()
                    for _ in 0..<400 {
                        if engine.hasFirstFrameReadyForDisplay, (engine.liveTelemetry?.observedFps ?? 0) > 5 {
                            print("DOCUMENTED_HOST advancing video elapsed=\(ProcessInfo.processInfo.systemUptime - started) time=\(engine.currentTime) fps=\(engine.liveTelemetry?.observedFps ?? 0)")
                            if CommandLine.arguments.contains("--controls") { try await controls(engine) }
                            return
                        }
                        if case .error(let message) = engine.state { throw PlayerError(message) }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw PlayerError("Documented host did not render advancing video")
                }
                media = try await PreparedMedia.stream(client: client, path: path, size: size, title: "Playback diagnostic", directory: Browser.cache, cancellation: CancellationFlag())
                _ = browser // Keep the isolated connection model alive during preparation.
                break
            } catch { print("PREPARATION_FAILED"); errors(error); try? await client.disconnectShare() }
        }
        guard let media, let stream = media.streaming else { throw PlayerError("No source prepared") }
        defer { stream.stop() }
        print("PREPARED vp9=\(media.info.vp9) codec=\(media.info.codec_type) aether=\(stream.aetherPlayback != nil)")
        if CommandLine.arguments.contains("--audio-continuity") {
            guard let backend = stream.aetherPlayback, backend.player == nil else {
                throw PlayerError("Audio continuity diagnostic requires the Aether software route.")
            }
            let engine = backend.engine
            MacPlaybackWindow.present(media: media) { }
            defer { MacSoftwarePlaybackWindow.current?.close() }
            for _ in 0..<200 {
                if engine.currentTime > 0.2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let start = CommandLine.arguments.first(where: { $0.hasPrefix("--audio-start=") })
                .flatMap { Double($0.dropFirst("--audio-start=".count)) }
            let end = CommandLine.arguments.first(where: { $0.hasPrefix("--audio-end=") })
                .flatMap { Double($0.dropFirst("--audio-end=".count)) }
            guard let start, let end, start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 180 else {
                throw PlayerError("Supply --audio-start and --audio-end in playback seconds, at most 180 seconds apart.")
            }
            await engine.seek(to: start)
            let tap = engine.installAudioTap()
            let collector = Task {
                var bucket = -1
                var peak: Float = 0
                var frames = 0
                var previousEnd: Double?
                for await sample in tap {
                    guard sample.sourceTime.isFinite, let channel = sample.buffer.floatChannelData?[0] else { continue }
                    let second = Int(sample.sourceTime)
                    if second != bucket {
                        if bucket >= 0 { print("AUDIO_PCM second=\(bucket) frames=\(frames) peak=\(peak)") }
                        bucket = second
                        frames = 0
                        peak = 0
                    }
                    if let previousEnd, sample.sourceTime - previousEnd > 0.2 {
                        print("AUDIO_TAP_GAP at=\(previousEnd) seconds=\(sample.sourceTime - previousEnd)")
                    }
                    let count = Int(sample.buffer.frameLength)
                    for index in 0..<count { peak = max(peak, abs(channel[index])) }
                    frames += count
                    previousEnd = sample.sourceTime + Double(count) / sample.buffer.format.sampleRate
                }
            }
            defer { collector.cancel(); engine.removeAudioTap() }
            engine.play()
            let deadline = ProcessInfo.processInfo.systemUptime + 240
            while engine.currentTime < end, ProcessInfo.processInfo.systemUptime < deadline {
                if case .error = engine.state { throw PlayerError("Audio continuity playback failed.") }
                try await Task.sleep(for: .seconds(1))
            }
            print("AUDIO_END playhead=\(engine.currentTime)")
            guard engine.currentTime >= end else { throw PlayerError("Audio continuity playback timed out.") }
            return
        }
        let hosted = CommandLine.arguments.contains("--hosted")
        var loader: StreamingFileLoader?
        let player: AVPlayer
        if hosted {
            MacPlaybackWindow.present(media: media) { print("HOST_CLOSED") }
            if let backend = stream.aetherPlayback, backend.player == nil {
                defer { MacSoftwarePlaybackWindow.current?.close() }
                func rendered(_ view: NSView?) -> Bool {
                    func layerRendered(_ layer: CALayer) -> Bool {
                        if let display = layer as? AVSampleBufferDisplayLayer, display.status == .rendering { return true }
                        return (layer.sublayers ?? []).contains(where: layerRendered)
                    }
                    guard let view else { return false }
                    return (view.layer.map(layerRendered) ?? false) || view.subviews.contains { rendered($0) }
                }
                for _ in 0..<400 {
                    if rendered(MacSoftwarePlaybackWindow.current?.window?.contentView),
                       backend.engine.currentTime > 5, (backend.engine.liveTelemetry?.observedFps ?? 0) > 5 {
                        print("PASS automatic fallback: Mac host rendering advancing video time=\(backend.engine.currentTime) fps=\(backend.engine.liveTelemetry?.observedFps ?? 0)")
                        if CommandLine.arguments.contains("--controls") { try await controls(backend.engine) }
                        return
                    }
                    if case .error(let message) = backend.engine.state { throw PlayerError(message) }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw PlayerError("Automatic fallback did not render advancing video")
            }
            guard let view = MacPlaybackWindow.current?.window?.contentView as? MacPlayerView, let native = view.player else { throw PlayerError("No hosted player") }
            player = native
        } else if let native = stream.aetherPlayer { player = native }
        else {
            loader = StreamingFileLoader(source: stream.source, fileExtension: "mp4")
            player = AVPlayer(playerItem: AVPlayerItem(asset: loader!.makeAsset()))
        }
        guard let item = player.currentItem else { print("SOFTWARE_ROUTE"); return }
        defer { MacPlaybackWindow.current?.close(); player.pause(); player.replaceCurrentItem(with: nil); _ = loader }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output)
        for _ in 0..<300 {
            if item.status != .unknown { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("ITEM_STATUS \(item.status.rawValue)"); errors(item.error)
        if item.status == .failed, CommandLine.arguments.contains("--verify-alternate"), let backend = stream.aetherPlayback {
            // Read-only diagnostic of the existing alternate path, not production routing.
            var options = LoadOptions()
            options.autoplay = false
            options.preferredDecodePath = .software
            options.sessionCacheByteBudget = 128 * 1024 * 1024
            try await backend.engine.load(source: .custom(AetherFileReader(source: stream.source), formatHint: "matroska"), options: options)
            backend.engine.play()
            func rendered(_ view: NSView?) -> Bool {
                func layerRendered(_ layer: CALayer) -> Bool {
                    if let display = layer as? AVSampleBufferDisplayLayer, display.status == .rendering { return true }
                    return (layer.sublayers ?? []).contains(where: layerRendered)
                }
                guard let view else { return false }
                return (view.layer.map(layerRendered) ?? false) || view.subviews.contains { rendered($0) }
            }
            defer { MacSoftwarePlaybackWindow.current?.close() }
            for _ in 0..<300 {
                if rendered(MacSoftwarePlaybackWindow.current?.window?.contentView), backend.engine.currentTime > 5, (backend.engine.liveTelemetry?.observedFps ?? 0) > 5 {
                    print("PASS alternate Mac host displaying advancing video, time=\(backend.engine.currentTime) fps=\(backend.engine.liveTelemetry?.observedFps ?? 0) route=\(backend.engine.videoRoute)")
                    return
                }
                if case .error(let message) = backend.engine.state { throw PlayerError(message) }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw PlayerError("Alternate Mac host did not render video")
        }
        guard item.status == .readyToPlay else { return }
        if !hosted {
            do { try await NativeAudioSelection.selectFirstSupported(in: item); print("AUDIO_SELECTION_OK") }
            catch { print("AUDIO_SELECTION_FAILED \(error.localizedDescription)"); errors(error); return }
            player.play()
        }
        if CommandLine.arguments.contains("--seek") {
            let files = saved["playbackFiles.v1"] as? [String: [String: String]] ?? [:]
            let positions = saved["playbackPositions.v1"] as? [String: [String: Double]] ?? [:]
            let target = files.first(where: { $0.value["path"] == path }).flatMap { positions[$0.key]?["seconds"] } ?? 6000
            let reached = await player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            print("SEEK completed=\(reached) target=\(target)"); errors(item.error)
        }
        for tick in 0..<300 {
            let time = player.currentTime()
            if output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil, time.seconds > 0.5 {
                print("PASS video frame time=\(time.seconds) fetched=\(stream.source.fetchedBytes)"); return
            }
            if item.status == .failed { print("PLAY_FAILED"); errors(item.error); return }
            if tick % 50 == 0 { print("WAIT clock=\(time.seconds) state=\(player.timeControlStatus.rawValue) fetched=\(stream.source.fetchedBytes)") }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("NO_VIDEO"); errors(item.error)
    }
}
import AMSMB2
