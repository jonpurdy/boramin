import OSLog
import AppKit
import AVKit
import SwiftUI
import Combine

private let macPlaybackLog = Logger(subsystem: "com.example.BoraMin", category: "Playback")

/// AVKit owns the Mac transport, keyboard shortcuts, media menus and full-screen UI.
/// The existing demuxed-video layer is placed in AVKit's public content overlay.
final class MacPlayerView: AVPlayerView {
    var sampleVideo: HardwareVideo?
    #if canImport(SwiftAssRenderer)
    var subtitleHost: PlaybackSubtitleHostingView?
    var subtitleMedia: PreparedMedia?
    #endif
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sampleVideo?.layer.frame = contentOverlayView?.bounds ?? bounds
        CATransaction.commit()
        #if canImport(SwiftAssRenderer)
        if let media = subtitleMedia, let host = subtitleHost {
            host.frame = contentOverlayView?.bounds ?? bounds
            host.rootView = PlaybackSubtitleOverlay(media: media, videoRect: videoBounds)
        }
        #endif
    }
}

@MainActor final class MacPlaybackWindow: NSWindowController, NSWindowDelegate {
    static private(set) var current: MacPlaybackWindow?
    private let media: PreparedMedia
    private let playerView = MacPlayerView()
    private var player: AVPlayer
    private let debugStats = PlaybackDebugStats()
    private var audioLoader: StreamingAudioLoader?
    private var fileLoader: StreamingFileLoader?
    private var readiness: NSKeyValueObservation?
    private var playbackStatus: NSKeyValueObservation?
    private var clock: Any?
    private var notifications: [NSObjectProtocol] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var startup: Task<Void, Never>?
    private var timer: Timer?
    private var debugLabel: NSTextField?
    private var began = false
    private var restored = false
    private var reportingFailure = false
    private var stopped = false
    private var completed = false
    private var lastCheckpoint = 0.0
    private var lastSampleTime = ProcessInfo.processInfo.systemUptime
    private var lastBytes: Int64 = 0
    private var onClose: (() -> Void)?
    private var tracks: PlaybackTracks?
    private var tracksHost: NSHostingView<PlaybackTracksButton>?
    #if canImport(AetherEngine)
    private var engineRouteObserver: AnyCancellable?
    #endif

    static func present(media: PreparedMedia, onClose: @escaping () -> Void) {
        current?.close()
        #if canImport(AetherEngine)
        MacSoftwarePlaybackWindow.current?.close()
        if let backend = media.streaming?.aetherPlayback, backend.player == nil {
            MacSoftwarePlaybackWindow.present(media: media, backend: backend, onClose: onClose)
            return
        }
        #endif
        do {
            let controller = try MacPlaybackWindow(media: media, onClose: onClose)
            current = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            media.streaming?.stop(); onClose()
            let alert = NSAlert(); alert.messageText = "Unable to Play Video"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    private init(media: PreparedMedia, onClose: @escaping () -> Void) throws {
        self.media = media; self.onClose = onClose
        let item: AVPlayerItem
        if let native = media.streaming?.aetherPlayer, let current = native.currentItem {
            item = current
        } else if media.usesSampleBufferVideo, let stream = media.streaming {
            let loader = try stream.makeAudioLoader(); audioLoader = loader
            item = AVPlayerItem(asset: loader.makeAsset())
        } else if let stream = media.streaming,
                  ["mp4", "m4v", "mov"].contains(media.timeline.pathExtension.lowercased()) {
            let loader = StreamingFileLoader(source: stream.source, fileExtension: media.timeline.pathExtension.lowercased())
            fileLoader = loader
            item = AVPlayerItem(asset: loader.makeAsset())
            macPlaybackLog.notice("Native SMB resource loader enabled")
        } else { item = AVPlayerItem(url: media.timeline) }
        item.preferredForwardBufferDuration = media.usesSampleBufferVideo ? 3 : 0
        player = media.streaming?.aetherPlayer ?? AVPlayer(playerItem: item)
        player.appliesMediaSelectionCriteriaAutomatically = true
        if media.usesSampleBufferVideo && media.streaming != nil { player.automaticallyWaitsToMinimizeStalling = false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        macPlaybackLog.notice("Playback opened session=\(media.id.uuidString, privacy: .public) title=\(media.title, privacy: .private) sampleBuffer=\(media.usesSampleBufferVideo) codec=\(media.info.codec_type) size=\(media.info.width)x\(media.info.height) fps=\(media.info.frame_rate)")
        window.title = media.title; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 270)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.contentView = playerView
        window.center()
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                macPlaybackLog.warning("Playback stalled session=\(self.media.id.uuidString, privacy: .public) position=\(item.currentTime().seconds) bufferEmpty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)")
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, let event = item.errorLog()?.events.last else { return }
                macPlaybackLog.error("Player error log session=\(self.media.id.uuidString, privacy: .public) code=\(event.errorStatusCode) domain=\(event.errorDomain, privacy: .private) comment=\(event.errorComment ?? "none", privacy: .private)")
            }
        })
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        #if canImport(SwiftAssRenderer)
        let tracks = PlaybackTracks(media: media); self.tracks = tracks
        tracks.bind(player: player)
        if media.streaming?.externalSubtitles != nil || media.streaming?.aetherPlayback?.styledSubtitles != nil, let overlay = playerView.contentOverlayView {
            let host = PlaybackSubtitleHostingView(rootView: PlaybackSubtitleOverlay(media: media))
            host.frame = overlay.bounds; host.autoresizingMask = [.width, .height]
            overlay.addSubview(host); playerView.subtitleHost = host; playerView.subtitleMedia = media
        }
        if let overlay = playerView.contentOverlayView {
            let host = NSHostingView(rootView: PlaybackTracksButton(tracks: tracks))
            host.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(host); tracksHost = host
            NSLayoutConstraint.activate([host.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -20), host.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 20)])
        }
        #endif
        if media.usesSampleBufferVideo {
            let video = HardwareVideo(path: media.source.path, remote: media.streaming?.source)
            playerView.sampleVideo = video
            playerView.contentOverlayView?.wantsLayer = true
            playerView.contentOverlayView?.layer?.insertSublayer(video.layer, at: 0)
            video.failure = { [weak self] message in self?.fail(message) }
            notifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    let time = item.currentTime().seconds
                    self.media.streaming?.updateClock(time)
                    self.playerView.sampleVideo?.seek(to: time)
                }
            })
        }
        installClock()
        observeItem(item)
        observePlayerStatus()
        if UserDefaults.standard.bool(forKey: "showDebugInfo") { installDebug() }
        #if canImport(AetherEngine)
        if let backend = media.streaming?.aetherPlayback {
            backend.onItemChanged = { [weak self] player, item in
                guard let self, !self.stopped else { return }
                if self.player !== player {
                    if let clock = self.clock { self.player.removeTimeObserver(clock); self.clock = nil }
                    self.player = player; self.playerView.player = player
                    self.installClock(); self.observePlayerStatus()
                }
                self.observeItem(item); self.tracks?.bind(player: player)
            }
            engineRouteObserver = backend.engine.$videoRoute.sink { [weak self] route in
                guard route == .software || route == .audio else { return }
                Task { @MainActor [weak self] in self?.switchToSoftware(backend) }
            }
        }
        #endif
    }
    private func installClock() {
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.media.streaming?.updateClock(time.seconds)
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastCheckpoint >= 15 {
                    let metrics = self.media.streaming?.source.transferMetrics
                    macPlaybackLog.notice("Playback health session=\(self.media.id.uuidString, privacy: .public) position=\(time.seconds) state=\(self.player.timeControlStatus.rawValue) residentBytes=\(media_process_resident_bytes()) cacheBytes=\(metrics?.cached ?? 0) cacheCapacity=\(metrics?.capacity ?? 0) fetchedBytes=\(metrics?.fetched ?? 0) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                    self.playerView.sampleVideo?.logPerformance(sessionID: self.media.id)
                    self.savePosition(); self.lastCheckpoint = now
                }
            }
        }
    }
    private func observeItem(_ item: AVPlayerItem) {
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }; itemNotifications.removeAll()
        readiness = nil
        itemNotifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.completed = true
                if let key = self.media.positionKey { PlaybackPositions.shared.clear(key) }
                self.close()
            }
        })
        itemNotifications.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.fail((note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Playback failed.") }
        })
        readiness = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if item.status == .failed { self.fail(item.error?.localizedDescription ?? "This video cannot be played."); return }
                guard item.status == .readyToPlay, !self.began else { return }
                self.began = true
                self.startup = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.media.usesSampleBufferVideo && self.media.streaming?.aetherPlayer == nil {
                        do { try await NativeAudioSelection.selectFirstSupported(in: item) }
                        catch { guard !self.stopped, !Task.isCancelled else { return }; self.fail(error.localizedDescription); return }
                    }
                    if let key = self.media.positionKey, let saved = PlaybackPositions.shared.position(for: key, duration: self.media.info.duration) {
                        let target = self.media.usesSampleBufferVideo ? (self.media.keyframes.last(where: { $0 <= saved }) ?? saved) : saved
                        _ = await self.player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    guard !Task.isCancelled, !self.stopped else { return }
                    self.restored = true
                    if let video = self.playerView.sampleVideo {
                        guard let timebase = item.timebase else { self.fail("Player timeline unavailable."); return }
                        video.seek(to: item.currentTime().seconds)
                        video.start(timebase: timebase)
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                    guard !Task.isCancelled, !self.stopped else { return }
                    self.player.play()
                }
            }
        }
    }
    private func observePlayerStatus() {
        playbackStatus = nil
        playbackStatus = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                macPlaybackLog.notice("Playback state session=\(self.media.id.uuidString, privacy: .public) state=\(player.timeControlStatus.rawValue) position=\(player.currentTime().seconds) waitingReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none", privacy: .public) bufferEmpty=\((player.currentItem?.isPlaybackBufferEmpty ?? false)) likelyToKeepUp=\((player.currentItem?.isPlaybackLikelyToKeepUp ?? false))")
                if player.timeControlStatus == .paused { self.savePosition() }
            }
        }
    }
    #if canImport(AetherEngine)
    private func switchToSoftware(_ backend: AetherMKVPlayback) {
        guard !stopped, media.streaming?.source.cancellation.cancelled != true else { return }
        let completion = onClose; onClose = nil
        stop(preservingAetherSession: true)
        window?.close()
        MacSoftwarePlaybackWindow.present(media: media, backend: backend) { completion?() }
    }
    #endif
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    func windowWillClose(_ notification: Notification) { stop() }
    func stop(preservingAetherSession: Bool = false) {
        guard !stopped else { return }
        macPlaybackLog.notice("Playback closing session=\(self.media.id.uuidString, privacy: .public) position=\(self.player.currentTime().seconds) completed=\(self.completed)")
        if !preservingAetherSession { savePosition() }
        stopped = true
        #if canImport(AetherEngine)
        engineRouteObserver = nil
        media.streaming?.aetherPlayback?.onItemChanged = nil
        #endif
        startup?.cancel(); timer?.invalidate()
        tracks?.stop(); tracks = nil; tracksHost?.removeFromSuperview(); tracksHost = nil
        readiness?.invalidate(); playbackStatus?.invalidate()
        for observer in notifications + itemNotifications { NotificationCenter.default.removeObserver(observer) }; notifications.removeAll(); itemNotifications.removeAll()
        if let clock { player.removeTimeObserver(clock); self.clock = nil }
        if !preservingAetherSession { player.pause(); media.streaming?.stop(); player.replaceCurrentItem(with: nil) }
        playerView.sampleVideo?.stop(); audioLoader?.stop(); fileLoader?.stop()
        playerView.player = nil
        let completion = onClose; onClose = nil; completion?()
        NotificationCenter.default.post(name: Notification.Name("BoraMinPlaybackSync"), object: nil)
        if Self.current === self { Self.current = nil }
    }
    private func savePosition() {
        guard !stopped, !completed, restored, let key = media.positionKey else { return }
        PlaybackPositions.shared.save(player.currentTime().seconds, duration: media.info.duration, for: key, subtitle: media.subtitleSelection)
    }
    private func fail(_ message: String, allowEngineRecovery: Bool = true) {
        guard !stopped, !reportingFailure else { return }
        #if canImport(AetherEngine)
        if allowEngineRecovery, let backend = media.streaming?.aetherPlayback {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.stopped, backend.engine.videoRoute != .software, backend.engine.videoRoute != .audio else { return }
                self.fail(message, allowEngineRecovery: false)
            }
            return
        }
        #endif
        macPlaybackLog.error("Playback failed session=\(self.media.id.uuidString, privacy: .public) message=\(message, privacy: .private)")
        reportingFailure = true
        player.pause()
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Playback Error"; alert.informativeText = message
        alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
    }
    private var decoder: String { media.usesSampleBufferVideo && media.info.vp9 != 0 ? "Hardware Decoding" : "System Decoding (HW/SW unknown)" }
    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white; label.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        label.drawsBackground = true; label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
    private func installDebug() {
        guard let overlay = playerView.contentOverlayView else { return }
        let label = label(""); debugLabel = label; overlay.addSubview(label)
        NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -20), label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualToConstant: 350)])
        lastBytes = media.streaming?.source.fetchedBytes ?? 0
        updateDebug()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateDebug() } }
    }
    private func updateDebug() {
        let now = ProcessInfo.processInfo.systemUptime
        let metrics = media.streaming?.source.transferMetrics ?? (fetched: 0, cached: 0, capacity: 0)
        let speed = Double(max(0, metrics.fetched - lastBytes)) / max(0.001, now - lastSampleTime) / 1_000_000
        debugLabel?.stringValue = String(format: " Network: %.2f MB/s \n Cache: %.1f / %.0f MiB \n Video: %d × %d, %.2f fps \n Decoder: %@ ", speed, Double(metrics.cached)/1048576, Double(metrics.capacity)/1048576, media.info.width, media.info.height, media.info.frame_rate, decoder)
        debugLabel?.stringValue += "\n " + debugStats.lines(item: player.currentItem, video: playerView.sampleVideo).joined(separator: " \n ")
        lastBytes = metrics.fetched; lastSampleTime = now
    }
}


#if canImport(AetherEngine)
/// Separate window host only for the engine's non-AVPlayer rendering path.
@MainActor final class MacSoftwarePlaybackWindow: NSWindowController, NSWindowDelegate {
    static var current: MacSoftwarePlaybackWindow?
    private let model: AetherSoftwareModel
    private var onClose: (() -> Void)?
    static func present(media: PreparedMedia, backend: AetherMKVPlayback, positions: PlaybackPositions? = nil, onClose: @escaping () -> Void) {
        let host = MacSoftwarePlaybackWindow(media: media, backend: backend, positions: positions ?? .shared, onClose: onClose)
        current = host
        host.showWindow(nil); host.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private init(media: PreparedMedia, backend: AetherMKVPlayback, positions: PlaybackPositions, onClose: @escaping () -> Void) {
        self.model = AetherSoftwareModel(media: media, backend: backend, positions: positions); self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = media.title; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.backgroundColor = .black; window.collectionBehavior = [.fullScreenPrimary]; window.delegate = self
        window.contentView = NSHostingView(rootView: AetherSoftwarePlayer(model: model, close: { [weak self] in self?.close() }, failure: { [weak self] message in
            guard let self, let window = self.window else { return }
            let alert = NSAlert(); alert.messageText = "Unable to Play Video"; alert.informativeText = message
            alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
        }))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    func stop() { model.stop() }
    func windowWillClose(_ notification: Notification) {
        model.stop()
        window?.contentView = nil
        let callback = onClose; onClose = nil; callback?()
        NotificationCenter.default.post(name: Notification.Name("BoraMinPlaybackSync"), object: nil)
        if Self.current === self { Self.current = nil }
    }
}

#endif
