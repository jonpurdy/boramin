// Standalone integration probe for the actual AppKit/AVKit window adapter.
// Fixtures are test inputs only; the Mac app remains an SMB browser/player.
import AppKit
import AVKit

@main @MainActor struct MacPlaybackProbe {
    static func wait(_ label: String, timeout: Double = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw PlayerError("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoraMinMacProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard CommandLine.arguments.count == 3 else { throw PlayerError("Pass native MP4 and short MKV fixtures.") }
        var dismissals = [false, false]
        var previousPlayer: AVPlayer?
        for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
            let media = try PreparedMedia.prepare(source: URL(fileURLWithPath: path), directory: directory,
                                                 title: "Mac playback probe", cancellation: CancellationFlag())
            MacPlaybackWindow.present(media: media) { dismissals[index] = true }
            if index > 0 {
                guard dismissals[index - 1], previousPlayer?.currentItem == nil else { throw PlayerError("Replacement did not stop the outgoing player.") }
            }
            guard let controller = MacPlaybackWindow.current, let view = controller.window?.contentView as? MacPlayerView,
                  let player = view.player, let item = player.currentItem else { throw PlayerError("No native player window.") }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            if !media.usesSampleBufferVideo { item.add(output) }
            try await wait("playback starts") { player.currentTime().seconds > 0.5 }
            if media.usesSampleBufferVideo {
                try await wait("MKV decoded video") { (view.sampleVideo?.queuedTime ?? -1) > 0.5 }
            } else {
                try await wait("native video pixels") { output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil }
                let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)
                print("Native groups audio=\(audio?.options.count ?? 0) subtitles=\(subtitles?.options.count ?? 0)")
                // macOS may expose additional native subtitle options.
                guard audio?.options.count == 2, (subtitles?.options.count ?? 0) >= 2 else { throw PlayerError("Native audio/subtitle groups missing.") }
                if let audio, let option = audio.options.last { item.select(option, in: audio) }
                if let subtitles, let option = subtitles.options.last { item.select(option, in: subtitles) }
                print("PASS: native MP4 video pixels and both native media-selection groups")
            }
            for target in [media.info.duration * 0.7, 1.0] {
                guard await player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) else { throw PlayerError("Seek failed.") }
                if media.usesSampleBufferVideo {
                    try await wait("MKV video after seek") { (view.sampleVideo?.queuedTime ?? -1) >= target && player.currentTime().seconds > target + 0.15 }
                } else {
                    try await wait("native pixels after seek") { player.currentTime().seconds > target + 0.15 && output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil }
                }
            }
            player.pause()
            let paused = player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(300))
            guard abs(player.currentTime().seconds - paused) < 0.1 else { throw PlayerError("Pause did not hold.") }
            player.play()
            if index == 0 { previousPlayer = player }
            else {
                _ = await player.seek(to: CMTime(seconds: max(0, media.info.duration - 0.25), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                try await wait("end closes player window") { dismissals[index] }
            }
            if index > 0 {
                guard dismissals[index], MacPlaybackWindow.current == nil else { throw PlayerError("Window teardown failed.") }
            }
            print("PASS: \(media.usesSampleBufferVideo ? "MKV" : "MP4") forward/backward seeks, pause, teardown, consecutive windows")
        }
        print("PASS: Mac native playback adapter integration")
    }
}
