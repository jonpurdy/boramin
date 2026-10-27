// Test-only local fixture. The shipped app remains an SMB player.
import SwiftUI
import AppKit
import AVKit
import AetherEngine
import SwiftAssRenderer
import ImageIO

@main @MainActor struct StyledASSPlaybackProbe {
    static func wait(_ label: String, timeout: Double = 20, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw PlayerError("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    static func pixels(_ image: CGImage) -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 2 else { throw PlayerError("Pass the generated styled MKV.") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = try AetherEngine()
        var options = LoadOptions(); options.autoplay = false; options.preserveASSMarkup = true; options.prepareNativeSubtitles = false
        guard let probe = try await engine.load(url: url, options: options), let player = engine.currentAVPlayer, let item = player.currentItem else {
            throw PlayerError("Native H.264/AAC engine path did not initialize.")
        }
        guard engine.fontAttachments.count == 1 else { throw PlayerError("Embedded font not extracted.") }
        var info = MediaInfo(); info.width = probe.videoWidth; info.height = probe.videoHeight; info.duration = probe.durationSeconds
        let backend = AetherMKVPlayback(engine: engine, info: info, enableStyledSubtitles: true)
        defer { backend.stop() }
        let coordinator = backend.styledSubtitles!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .floating; view.videoGravity = .resizeAspect
        window.contentView = view
        let host = SubtitleHostingView(rootView: AetherSubtitleOverlay(backend: backend))
        host.frame = view.bounds; host.autoresizingMask = [.width, .height]; view.contentOverlayView!.addSubview(host)
        window.makeKeyAndOrderFront(nil)
        defer { view.player = nil; window.close() }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output)
        guard let styled = engine.subtitleTracks.first(where: { StyledASSCoordinator.isASS($0.codec) }),
              let plain = engine.subtitleTracks.first(where: { !StyledASSCoordinator.isASS($0.codec) }) else { throw PlayerError("Both subtitle tracks are required.") }
        backend.selectSubtitle(index: styled.id)
        engine.play()
        try await wait("native decoded video pixels") { output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil && engine.currentTime > 1 }
        try await wait("styled libass bitmap") { coordinator.frame != nil }
        let first = coordinator.frame!
        guard first.imageRect.minY < 80, first.imageRect.minX < 120 else { throw PlayerError("ASS positioning was not preserved.") }
        let data = pixels(first.image)
        var red = 0, green = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i+1]), b = Int(data[i+2])
            if r > 80 && r > g * 2 && r > b * 2 { red += 1 }
            if g > 80 && g > r * 2 && g > b * 2 { green += 1 }
        }
        guard red > 20, green > 20 else { throw PlayerError("ASS colors were not preserved.") }
        let imageURL = url.deletingLastPathComponent().appendingPathComponent("styled-render.png")
        if let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, first.image, nil); CGImageDestinationFinalize(destination)
        }
        print("PASS native decoded video plus positioned colored ASS bitmap; embedded font delivered to libass")
        await engine.seek(to: 7)
        try await wait("seeked styled video") { engine.currentTime >= 7 && coordinator.frame != nil }
        try await wait("animated frame changes") { coordinator.frame.map { pixels($0.image) != data } ?? false }
        engine.pause()
        let paused = engine.currentTime
        try await Task.sleep(for: .milliseconds(250))
        guard abs(engine.currentTime - paused) < 0.15 else { throw PlayerError("Native pause drifted.") }
        backend.selectSubtitle(index: plain.id)
        try await wait("plain subtitle selection") { !coordinator.active && coordinator.frame == nil }
        backend.selectSubtitle(index: styled.id)
        try await wait("ASS reselection") { coordinator.active && coordinator.frame != nil }
        backend.selectSubtitle(index: -1)
        try await wait("subtitle Off clears overlay") { coordinator.frame == nil && !coordinator.active }
        guard engine.currentAVPlayer === player else { throw PlayerError("Subtitle selection replaced native video/audio player.") }
        backend.selectSubtitle(index: styled.id)
        engine.play()
        await engine.seek(to: 2)
        try await wait("backward seek restores styled bitmap") { engine.currentTime >= 2 && engine.currentTime < 5 && coordinator.frame != nil }
        backend.stop()
        guard coordinator.frame == nil && engine.state == .idle else { throw PlayerError("Stop left subtitle resources active.") }
        print("PASS forward/backward seeks, animation, pause, ASS/SRT/Off switching and teardown; original AVPlayer retained")
    }
}

@MainActor final class MacLibrary: ObservableObject {
    let files = Browser(); let favoritesBrowser = Browser(); let watchingBrowser = Browser()
    @Published var showConnection = false
}
