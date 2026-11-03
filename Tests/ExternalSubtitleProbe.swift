// Isolated fixtures only; no SMB credentials, user history or iCloud access.
import SwiftUI
import AppKit
import AVKit
import AetherEngine
import AMSMB2

@main @MainActor struct ExternalSubtitleProbe {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PlayerError(message) }
    }
    static func wait(_ label: String, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
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
    static func testEmbeddedPGS(folder: URL) async throws {
        let bytes = try Data(contentsOf: folder.appendingPathComponent("pgs.mkv"))
        let source = CachedRemoteFile(size: Int64(bytes.count), cancellation: CancellationFlag()) { range, _, _, completion in
            completion(.success(bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))))
            return nil
        }
        let transport = try StreamingSession(source: source, fileExtension: "mkv")
        defer { transport.stop() }
        try await transport.start()
        let timeline = try await transport.configureAetherPlayback()
        guard let backend = transport.aetherPlayback, let player = backend.player, let item = player.currentItem else {
            throw PlayerError("PGS fixture did not use native Aether video")
        }
        try require(backend.styledSubtitles == nil && transport.externalSubtitles == nil, "PGS fixture unexpectedly has ASS/external rendering")
        let media = PreparedMedia(title: "PGS fixture", source: transport.sourceURL, timeline: timeline,
            usesSampleBufferVideo: false, directory: folder, info: backend.info, streaming: transport, keyframes: [])
        let panel = PlaybackTracks(media: media)
        defer { panel.stop() }
        panel.bind(player: player)
        try await wait("PGS menu readiness") { panel.subtitles.ready }
        guard let pgs = backend.engine.subtitleTracks.first(where: { $0.codec.lowercased().contains("pgs") }),
              let plain = backend.engine.subtitleTracks.first(where: { ["subrip", "srt"].contains($0.codec) }) else {
            throw PlayerError("Embedded PGS and SRT tracks missing: \(backend.engine.subtitleTracks.map(\.codec))")
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output)
        panel.subtitles.select("embedded:\(pgs.id)")
        backend.engine.play()
        try await wait("decoded native video and PGS image cue") {
            output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil &&
            backend.engine.subtitleCues.contains { cue in
                guard case .image = cue.body else { return false }
                return backend.engine.sourceTime >= cue.startTime && backend.engine.sourceTime < cue.endTime
            }
        }
        backend.engine.pause()
        func captionPixels() -> Int {
            let renderer = ImageRenderer(content: PlaybackSubtitleOverlay(media: media).frame(width: 640, height: 360))
            guard let image = renderer.cgImage else { return 0 }
            let data = pixels(image)
            return stride(from: 0, to: data.count, by: 4).filter { data[$0] > 200 && data[$0 + 1] > 200 && data[$0 + 2] > 200 && data[$0 + 3] > 200 }.count
        }
        try await wait("PGS pixels in production caption overlay") { captionPixels() >= 1000 }
        panel.subtitles.select("off")
        try await wait("PGS Off clears caption pixels") { backend.engine.activeSubtitleTrackIndex == nil && captionPixels() == 0 }
        panel.subtitles.select("embedded:\(pgs.id)")
        try await wait("PGS reselection renders") { captionPixels() >= 1000 }
        await backend.engine.seek(to: 8)
        try await wait("PGS pixels after seek") { backend.engine.sourceTime >= 7 && captionPixels() >= 1000 }
        panel.subtitles.select("embedded:\(plain.id)")
        let nativeGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        try await wait("SRT selects native caption option") {
            guard let group = nativeGroup else { return false }
            return item.currentMediaSelection.selectedMediaOption(in: group) != nil && captionPixels() == 0
        }
        try require(backend.player === player && player.currentItem === item, "Subtitle selection replaced video playback")
        print("PASS native Aether PGS menu selection renders pixels without ASS/external tracks; Off, reselection, seek and native SRT switching preserve the player")
    }
    static func testSubtitleResume(player: AVPlayer, tracks: [ExternalSubtitles.Track], defaults: UserDefaults) async throws {
        let positions = PlaybackPositions(defaults: defaults), key = "subtitle-resume-fixture"
        var selected: SavedSubtitleSelection?
        let first = ExternalSubtitles(tracks: tracks), panel = PlaybackTracks(subtitles: first, backend: nil)
        panel.configureBookmark(key: key, positions: positions) { selected = $0 }
        panel.bind(player: player); first.setCanvas(CGSize(width: 640, height: 360), scale: 1)
        try await wait("resume fixture tracks ready") { first.ready }
        first.select("external:srt")
        try await wait("capture selected external subtitle") { first.frame != nil && selected?.kind == .external }
        try require(positions.progress(for: key) == nil && positions.subtitleSelection(for: key) == nil, "Subtitle selection created an orphan bookmark")
        positions.save(2, duration: 18, for: key, subtitle: selected)
        let external = positions.subtitleSelection(for: key)!
        panel.stop(); first.stop()

        let second = ExternalSubtitles(tracks: tracks), reopened = PlaybackTracks(subtitles: second, backend: nil)
        reopened.configureBookmark(key: key, positions: positions) { selected = $0 }
        reopened.bind(player: player); second.setCanvas(CGSize(width: 640, height: 360), scale: 1)
        try await wait("reopen automatically restores actual external pixels") { second.selection == "external:srt" && second.frame != nil }
        try require(positions.subtitleSelection(for: key) == external, "Restore changed the saved subtitle identity")
        second.select("off")
        try await wait("explicit Off is saved") { positions.subtitleSelection(for: key)?.kind == .off }
        try await wait("native options for saved selection") { !second.embedded.isEmpty }
        second.select(second.embedded[0].id)
        try await wait("native subtitle property list saved") { positions.subtitleSelection(for: key)?.kind == .native }
        let native = positions.subtitleSelection(for: key)!
        try require(native.nativePropertyList != nil, "No public AVFoundation subtitle identity captured")
        reopened.stop(); second.stop()

        // A new item/asset, not a reused menu index from the previous controller.
        let fresh = AVPlayer(playerItem: AVPlayerItem(asset: player.currentItem!.asset))
        let third = ExternalSubtitles(tracks: tracks), nativePanel = PlaybackTracks(subtitles: third, backend: nil)
        defer { nativePanel.stop(); third.stop(); fresh.pause(); fresh.replaceCurrentItem(with: nil) }
        nativePanel.configureBookmark(key: key, positions: positions) { selected = $0 }
        nativePanel.bind(player: fresh)
        try await wait("native subtitle restored on new item") { third.ready && third.selection.hasPrefix("embedded:") }
        try require(third.savedSelection?.kind == .native, "Native restore picked an external track")
        nativePanel.stop(); third.stop()

        positions.save(2, duration: 18, for: key, subtitle: SavedSubtitleSelection(kind: .external, filename: "missing.ass"))
        let missing = ExternalSubtitles(tracks: tracks), missingPanel = PlaybackTracks(subtitles: missing, backend: nil)
        defer { missingPanel.stop(); missing.stop() }
        missingPanel.configureBookmark(key: key, positions: positions) { selected = $0 }
        missingPanel.bind(player: fresh)
        try await wait("missing subtitle remains Off") { missing.ready && missing.selection == "off" }
        try require(positions.subtitleSelection(for: key)?.filename == "missing.ass", "Missing subtitle silently replaced the saved choice")
        missing.select("off")
        try await wait("explicit Off overrides missing saved subtitle") { positions.subtitleSelection(for: key)?.kind == .off }
        positions.clear(key)
        missing.select("external:ass"); missing.setCanvas(CGSize(width: 640, height: 360), scale: 1); missing.update(time: 2)
        try await wait("selection after reset") { missing.frame != nil }
        try require(positions.subtitleSelection(for: key) == nil && positions.progress(for: key) == nil, "Selection resurrected a reset bookmark")
        positions.save(2, duration: 18, for: key, subtitle: selected)
        positions.save(18, duration: 18, for: key)
        try require(positions.subtitleSelection(for: key) == nil, "Completion retained subtitles")
        print("PASS bookmark-scoped external/native subtitle restoration, missing-track safety, explicit Off, reset and completion")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let srt = Data("1\n00:00:01,000 --> 00:00:05,000\n<i>Hello</i>, external subtitles\n\n2\n00:00:10,000 --> 00:00:15,000\nAfter a distant seek\n".utf8)
        let vtt = Data("WEBVTT\n\n00:01.000 --> 00:05.000\n<b>WebVTT</b> subtitles\n\n00:10.000 --> 00:15.000\nLater cue\n".utf8)
        let ass = try Data(contentsOf: folder.appendingPathComponent("styled.ass"))
        try require(ExternalSubtitles.matches(videoName: "Movie.mp4", subtitleName: "Movie.SRT"), "Uppercase extension failed")
        try require(ExternalSubtitles.matches(videoName: "Movie.mp4", subtitleName: "Movie.en.srt"), "Recognized language suffix did not match")
        try require(!ExternalSubtitles.matches(videoName: "Movie.mp4", subtitleName: "Other.ass"), "Unrelated subtitle matched")
        for (ext, data) in [("srt", srt), ("vtt", vtt), ("ass", ass), ("ssa", ass)] {
            let document = try await Task.detached { try ExternalSubtitleDecoder.decode(data, extension: ext, cancellation: CancellationFlag()) }.value
            try require(!document.header.isEmpty && !document.cues.isEmpty, "No ASS events for \(ext)")
            if ["srt", "vtt"].contains(ext) {
                try require(document.cues.count == 2 && abs(document.cues[0].startTime - 1) < 0.01 && abs(document.cues[1].startTime - 10) < 0.01, "Incorrect \(ext) cue timing")
            }
            print("PASS \(ext) decoded to timed ASS events: \(document.cues.count)")
        }
        if CommandLine.arguments.count == 5 {
            // Optional real SMB regression. Credentials are read from ignored
            // local files, never compiled into the app or printed.
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            func value(_ name: String) throws -> String {
                try String(contentsOf: root.appendingPathComponent("default_\(name).txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let address = try value("server")
            let url = URL(string: address.contains("://") ? address : "smb://" + address)!
            let client = SMB2Manager(url: url, credential: URLCredential(user: try value("username"), password: try value("password"), persistence: .none))!
            try await client.connectShare(name: CommandLine.arguments[3])
            let path = CommandLine.arguments[4]
            let entries = try await client.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
            for entry in entries {
                if let name = entry[.nameKey] as? String {
                    print("SMB entry=\(name) regular=\(entry[.fileResourceTypeKey] as? URLFileResourceType == .regular) matching=\(ExternalSubtitles.matches(videoName: (path as NSString).lastPathComponent, subtitleName: name))")
                }
            }
            guard let discovered = await ExternalSubtitles.discover(session: RemoteSession(smb: client), path: path, playbackCancellation: CancellationFlag()), !discovered.tracks.isEmpty else { throw PlayerError("No matching SMB subtitle discovered") }
            let track = discovered.tracks[0]
            let bytes = try await track.load(CancellationFlag())
            let document = try await Task.detached { try ExternalSubtitleDecoder.decode(bytes, extension: track.ext, cancellation: CancellationFlag()) }.value
            discovered.bind(player: AVPlayer(), backend: nil)
            discovered.setCanvas(CGSize(width: 1920, height: 1080), scale: 1)
            discovered.update(time: document.cues[0].startTime + 0.1)
            discovered.select("external:" + track.id)
            try await wait("actual SMB subtitle pixels") { discovered.frame != nil || discovered.error != nil }
            try require(discovered.frame != nil && discovered.error == nil, "Actual SMB subtitle failed: \(discovered.error ?? "")")
            discovered.stop()
            print("PASS actual SMB subtitle discovery, bounded download, decode and libass pixels")
            let attributes = try await client.attributesOfItem(atPath: path)
            let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            let media = try await PreparedMedia.stream(client: client, path: path, size: size, title: "BoraMin subtitle check", directory: FileManager.default.temporaryDirectory, cancellation: CancellationFlag())
            guard let production = media.streaming?.externalSubtitles else { throw PlayerError("Production stream lost the external subtitle coordinator") }
            MacPlaybackWindow.present(media: media, onClose: {})
            guard let controller = MacPlaybackWindow.current,
                  let view = controller.window?.contentView as? MacPlayerView, view.subtitleHost != nil else { throw PlayerError("Production Mac player did not install its subtitle overlay/menu") }
            production.select("external:" + production.tracks[0].id)
            _ = await view.player?.seek(to: CMTime(seconds: document.cues[0].startTime + 0.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try await wait("production SMB subtitle pixels") { production.frame != nil || production.error != nil }
            try require(production.frame != nil && production.error == nil, "Production subtitle overlay did not render")
            controller.close()
            try? await client.disconnectShare(gracefully: true)
            print("PASS actual SMB production preparation, Mac subtitle menu/overlay host and timed libass pixels")
        }
        do {
            _ = try ExternalSubtitleDecoder.decode(Data("garbage".utf8), extension: "srt", cancellation: CancellationFlag())
            throw PlayerError("Malformed subtitle was accepted")
        } catch let error as PlayerError { try require(error.message != "Malformed subtitle was accepted", error.message) }
        let cancelled = CancellationFlag(); cancelled.cancel()
        do {
            _ = try ExternalSubtitleDecoder.decode(srt, extension: "srt", cancellation: cancelled)
            throw PlayerError("Cancelled subtitle was accepted")
        } catch is CancellationError { }
        let tracks: [ExternalSubtitles.Track] = [("srt", srt), ("vtt", vtt), ("ass", ass)].map { ext, data in
            ExternalSubtitles.Track(id: ext, name: ext, ext: ext, load: { _ in data })
        } + [ExternalSubtitles.Track(id: "slow", name: "slow", ext: "srt", load: { _ in
            try await Task.sleep(for: .milliseconds(200)); return srt
        })]
        let suite = "BoraMin-subtitle-size-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = SubtitleAppearance(defaults: defaults)
        try require(appearance.percent == 125, "Subtitle size default must be 125%")
        appearance.select(150)
        try require(SubtitleAppearance(defaults: defaults).percent == 150, "Subtitle size did not persist")
        appearance.select(999)
        try require(appearance.percent == 150, "Invalid subtitle size accepted")
        appearance.select(100)
        let subtitles = ExternalSubtitles(tracks: tracks, appearance: appearance)
        let trackPanel = PlaybackTracks(subtitles: subtitles, backend: nil)
        let player = AVPlayer(url: folder.appendingPathComponent("external-fixture.mp4"))
        defer { trackPanel.stop(); subtitles.stop(); player.pause(); player.replaceCurrentItem(with: nil) }
        trackPanel.bind(player: player)
        subtitles.setCanvas(CGSize(width: 640, height: 360), scale: 1)
        try await wait("embedded MP4 option loaded") { !subtitles.embedded.isEmpty }
        let originalItem = player.currentItem!
        if let audio = try await originalItem.asset.loadMediaSelectionGroup(for: .audible), !audio.options.isEmpty {
            try await wait("panel audio rows") { trackPanel.audio.count == audio.options.count }
            guard let supported = trackPanel.audio.first(where: { $0.supported }) else { throw PlayerError("Panel disabled supported AAC audio") }
            trackPanel.selectAudio(supported.id)
            try await wait("panel audio selection") { trackPanel.selectedAudio == supported.id }
        }
        for ext in ["srt", "vtt", "ass"] {
            _ = await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            subtitles.update(time: 2); subtitles.select("external:" + ext)
            try await wait("\(ext) libass pixels") { subtitles.frame != nil || subtitles.error != nil }
            try require(subtitles.error == nil && subtitles.frame!.image.width > 0, "\(ext) render failed: \(subtitles.error ?? "")")
            let first = subtitles.frame!, firstPixels = pixels(first.image)
            if ext == "ass" {
                try require(first.imageRect.minX < 120 && first.imageRect.minY < 80, "External ASS positioning was lost")
                var red = 0, green = 0
                for index in stride(from: 0, to: firstPixels.count, by: 4) {
                    let r = Int(firstPixels[index]), g = Int(firstPixels[index+1]), b = Int(firstPixels[index+2])
                    if r > 80 && r > g * 2 && r > b * 2 { red += 1 }
                    if g > 80 && g > r * 2 && g > b * 2 { green += 1 }
                }
                try require(red > 20 && green > 20, "External ASS colors were lost")
            }
            _ = await player.seek(to: CMTime(seconds: 11, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            subtitles.update(time: 11)
            try await wait("forward seek changes actual subtitle pixels") { subtitles.frame.map { $0.imageRect != first.imageRect || pixels($0.image) != firstPixels } ?? false }
            _ = await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            subtitles.update(time: 2)
            try await wait("backward seek restores subtitle") { subtitles.frame.map { pixels($0.image) == firstPixels } ?? false }
            subtitles.select("off")
            try require(subtitles.frame == nil && !subtitles.externalSelected, "Off left external pixels")
        }
        _ = await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        subtitles.update(time: 2); subtitles.select("external:srt")
        try await wait("size test base bitmap") { subtitles.frame != nil }
        let originalSize = subtitles.frame!.imageRect.size
        appearance.select(200)
        try await wait("paused subtitle doubles in size") { subtitles.frame.map { $0.imageRect.height > originalSize.height * 1.5 } ?? false }
        appearance.select(100)
        try await wait("paused subtitle restores original size") { subtitles.frame?.imageRect.size == originalSize }
        print("PASS subtitle size default, persistence, bounds and paused 100%/200% libass rendering")
        subtitles.select(subtitles.embedded[0].id)
        let group = try await originalItem.asset.loadMediaSelectionGroup(for: .legible)!
        try require(originalItem.currentMediaSelection.selectedMediaOption(in: group) != nil, "Embedded subtitle did not select")
        subtitles.select("external:srt")
        try await wait("external replaces embedded") { subtitles.frame != nil }
        try require(originalItem.currentMediaSelection.selectedMediaOption(in: group) == nil, "Embedded subtitles duplicated external")
        // Selecting through AVKit itself must dismiss the external overlay too.
        originalItem.select(group.options[0], in: group)
        try await wait("AVKit selection clears external") { !subtitles.externalSelected && subtitles.frame == nil }
        subtitles.select("external:slow"); subtitles.select("off")
        try await Task.sleep(for: .milliseconds(300))
        try require(subtitles.frame == nil && subtitles.error == nil && !subtitles.loading, "Cancelled load published stale subtitles")
        try require(player.currentItem === originalItem, "Subtitle selection replaced MP4 video/audio")
        subtitles.stop()
        try await testSubtitleResume(player: player, tracks: tracks, defaults: defaults)
        print("PASS native MP4 libass pixels, forward seek, embedded/external/Off, AVKit selection, cancellation, teardown; video item retained")

        let engine = try AetherEngine()
        var options = LoadOptions(); options.autoplay = false; options.preserveASSMarkup = true; options.prepareNativeSubtitles = false
        guard let probe = try await engine.load(url: folder.appendingPathComponent("styled.mkv"), options: options) else { throw PlayerError("MKV fixture failed") }
        var info = MediaInfo(); info.width = probe.videoWidth; info.height = probe.videoHeight; info.duration = probe.durationSeconds
        let backend = AetherMKVPlayback(engine: engine, info: info, enableStyledSubtitles: true)
        let mkvSubtitles = ExternalSubtitles(tracks: tracks)
        let mkvPanel = PlaybackTracks(subtitles: mkvSubtitles, backend: backend)
        defer { mkvPanel.stop(); mkvSubtitles.stop(); backend.stop() }
        mkvPanel.bind(player: backend.player)
        mkvSubtitles.setCanvas(CGSize(width: 640, height: 360), scale: 1)
        await engine.seek(to: 2)
        try await wait("MKV embedded options") { !mkvSubtitles.embedded.isEmpty }
        try await wait("MKV panel audio rows") { mkvPanel.audio.count == engine.audioTracks.count && !mkvPanel.audio.isEmpty }
        mkvPanel.selectAudio(mkvPanel.audio[0].id)
        mkvSubtitles.select(mkvSubtitles.embedded[0].id)
        try await wait("MKV embedded ASS selection") { backend.styledSubtitles?.active == true }
        mkvSubtitles.select("external:ass")
        try await wait("MKV external ASS pixels") { mkvSubtitles.frame != nil }
        try require(engine.activeSubtitleTrackIndex == nil && backend.styledSubtitles?.active == false, "Embedded ASS remained active")
        mkvSubtitles.select(mkvSubtitles.embedded[0].id)
        try await wait("return to embedded ASS") { backend.styledSubtitles?.active == true && !mkvSubtitles.externalSelected }
        mkvSubtitles.select("off")
        try await wait("MKV Off") { engine.activeSubtitleTrackIndex == nil && backend.styledSubtitles?.active == false }
        mkvPanel.stop(); mkvSubtitles.stop()
        let positions = PlaybackPositions(defaults: defaults)
        let embedded = engine.subtitleTracks.first(where: { StyledASSCoordinator.isASS($0.codec) })!
        let choice = SavedSubtitleSelection(kind: .engine, stream: embedded.id, name: embedded.name, language: embedded.language, codec: embedded.codec)
        positions.save(2, duration: probe.durationSeconds, for: "mkv-resume", subtitle: choice)
        let resumed = ExternalSubtitles(tracks: tracks), resumedPanel = PlaybackTracks(subtitles: resumed, backend: backend)
        defer { resumedPanel.stop(); resumed.stop() }
        resumedPanel.configureBookmark(key: "mkv-resume", positions: positions) { _ in }
        resumedPanel.bind(player: backend.player)
        try await wait("MKV source subtitle restored") { engine.activeSubtitleTrackIndex == embedded.id && backend.styledSubtitles?.active == true }
        try require(positions.subtitleSelection(for: "mkv-resume") == choice, "MKV restore changed the selected source identity")
        print("PASS embedded MKV subtitle identity automatically restores through the public engine API")
        print("PASS unified track panel audio rows/selections, MKV embedded/external ASS switching and Off through public engine APIs")
        try await testEmbeddedPGS(folder: folder)
    }
}

@MainActor final class MacLibrary: ObservableObject {
    let files = Browser(); let favoritesBrowser = Browser(); let watchingBrowser = Browser()
    @Published var showConnection = false
}
