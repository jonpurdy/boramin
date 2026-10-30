// Read-only real-file diagnostic. Uses isolated preferences and existing Keychain credentials.
import AppKit
import AVFoundation
import AetherEngine
import Darwin

@main @MainActor struct PlaybackFailureProbe {
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
        let path = mode == "kpop" ? "playback-tests/compatibility/fallback.mkv" : "playback-tests/surround/surround.mp4"
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
            let client = AMSMB2.SMB2Manager(url: url, domain: connection.domain, credential: URLCredential(user: connection.username.isEmpty ? "guest" : connection.username, password: store.password(address: connection.server, username: connection.username, domain: connection.domain) ?? "", persistence: .none))!
            client.timeout = 8
            do {
                try await client.connectShare(name: "media")
                let attrs = try await client.attributesOfItem(atPath: path), size = (attrs[.fileSizeKey] as! NSNumber).int64Value
                EngineLog.handler = { print($0) }
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
