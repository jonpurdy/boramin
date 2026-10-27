// Standalone Mac UI integration test. Synthetic local files are test inputs only.
import SwiftUI
import AppKit
import AVKit
import AetherEngine

@main @MainActor struct AetherSoftwarePlaybackProbe {
    static func wait(_ label: String, timeout: Double = 20, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { throw PlayerError("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    static func hasRenderedVideo(_ view: NSView?) -> Bool {
        func rendered(_ layer: CALayer) -> Bool {
            if let display = layer as? AVSampleBufferDisplayLayer, display.status == .rendering { return true }
            return (layer.sublayers ?? []).contains(where: rendered)
        }
        guard let view else { return false }
        return (view.layer.map(rendered) ?? false) || view.subviews.contains { hasRenderedVideo($0) }
    }
    static func payload(_ path: String, key: String?) async throws -> (PreparedMedia, AetherMKVPlayback) {
        let url = URL(fileURLWithPath: path)
        let engine = try AetherEngine()
        var options = LoadOptions(); options.autoplay = false
        let probe = try await engine.load(url: url, options: options)
        var info = MediaInfo()
        info.duration = probe?.durationSeconds ?? engine.duration
        info.width = probe?.videoWidth ?? 640; info.height = probe?.videoHeight ?? 360
        info.frame_rate = probe?.videoFrameRate ?? 24
        let backend = AetherMKVPlayback(engine: engine, info: info)
        let media = PreparedMedia(title: "BoraMin synthetic software playback test", source: url, timeline: url,
                                  usesSampleBufferVideo: false, directory: url.deletingLastPathComponent(), info: info,
                                  streaming: nil, keyframes: [], positionKey: key)
        return (media, backend)
    }
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count >= 2 else { throw PlayerError("Pass a synthetic MPEG-4 AVI fixture.") }
        let path = CommandLine.arguments[1]
        let domain = "BoraMinSoftwareProbe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let positions = PlaybackPositions(defaults: defaults)
        let key = "synthetic-avi"
        var firstSaved = 0.0
        for cycle in 0..<2 {
            let (media, backend) = try await payload(path, key: key)
            guard backend.player == nil else { throw PlayerError("Fixture did not select software playback.") }
            if cycle == 0 { positions.save(3, duration: media.info.duration, for: key) }
            var closed = false
            MacSoftwarePlaybackWindow.present(media: media, backend: backend, positions: positions) { closed = true }
            try await wait("software video actually renders") { hasRenderedVideo(MacSoftwarePlaybackWindow.current?.window?.contentView) }
            try await wait("resume advances") { backend.engine.currentTime > (cycle == 0 ? 3.2 : firstSaved + 0.15) }
            backend.engine.pause()
            let paused = backend.engine.currentTime
            try await Task.sleep(for: .milliseconds(350))
            guard abs(backend.engine.currentTime - paused) < 0.15 else { throw PlayerError("Pause drifted.") }
            if cycle == 0 {
                guard backend.engine.audioTracks.count == 2 else { throw PlayerError("Audio tracks missing.") }
                let secondAudio = backend.engine.audioTracks[1].id
                backend.engine.selectAudioTrack(index: secondAudio)
                try await wait("second audio is selected") { backend.engine.activeAudioTrackIndex == secondAudio }
                backend.engine.play()
                await backend.engine.seek(to: 10)
                try await wait("forward seek") { backend.engine.currentTime >= 10 && hasRenderedVideo(MacSoftwarePlaybackWindow.current?.window?.contentView) }
                await backend.engine.seek(to: 5)
                try await wait("backward seek") { backend.engine.currentTime >= 5 && backend.engine.currentTime < 8 }
                MacSoftwarePlaybackWindow.current?.close()
                guard closed, backend.engine.state == .idle,
                      let saved = positions.progress(for: key), saved.seconds >= 5 else {
                    throw PlayerError("Window close did not save/stop.")
                }
                firstSaved = saved.seconds
                print("PASS software frames, resume, pause, audio switch, forward/backward seek, close/save/stop")
            } else {
                backend.engine.play()
                await backend.engine.seek(to: media.info.duration - 0.5)
                try await wait("completion dismisses window") { closed }
                guard positions.progress(for: key) == nil, backend.engine.state == .idle else {
                    throw PlayerError("Completion did not clear bookmark and stop.")
                }
                print("PASS consecutive software window, saved-position resume, completion dismissal and bookmark cleanup")
            }
        }
        print("PASS AetherEngine software playback UI integration")
    }
}

// Shared Mac browser types compile alongside the real player in this isolated target.
@MainActor final class MacLibrary: ObservableObject {
    let files = Browser()
    let favoritesBrowser = Browser()
    let watchingBrowser = Browser()
    @Published var showConnection = false
}
