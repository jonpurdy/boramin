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
    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let mode = CommandLine.arguments.dropFirst().first ?? "blade"
        let path = mode.hasPrefix("kpop") ? "playback-tests/compatibility/fallback\(mode == "kpop-remux" ? " remuxed" : "").mkv" : "playback-tests/surround/surround.mp4"
        let pref = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.example.BoraMin/Data/Library/Preferences/com.example.BoraMin.plist")
        let saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: pref), format: nil) as! [String: Any]
        let suite = "BoraMinPlaybackFailureProbe-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved["serverProfiles.v1"], forKey: "serverProfiles.v1")
        let store = ConnectionPreferences(defaults: defaults)
        var media: PreparedMedia?
        for connection in store.connections {
            let browser = Browser(connections: store, metadataCache: MediaMetadataCache(defaults: defaults))
            guard let url = URL(string: connection.server) else { continue }
            let client = AMSMB2.SMB2Manager(url: url, domain: connection.domain, credential: URLCredential(user: connection.username.isEmpty ? "guest" : connection.username, password: store.password(connectionID: connection.id) ?? "", persistence: .none))!
            client.timeout = 8
            do {
                try await client.connectShare(name: "media")
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
