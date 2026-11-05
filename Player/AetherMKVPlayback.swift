#if canImport(AetherEngine)
import Foundation
import AVFoundation
import AetherEngine
import Combine

/// Independent cursors share BoraMin's bounded remote-file cache. Cancellation interrupts
/// only the current operation, so an engine probe can cancel without closing the remote session.
final class AetherFileReader: IOReader, @unchecked Sendable {
    private let source: CachedRemoteFile
    private let cursorLock = NSLock()
    private let stateLock = NSLock()
    private var cursor: Int64 = 0
    private var closed = false
    private var operation: CancellationFlag?
    init(source: CachedRemoteFile) { self.source = source }
    var discImageProbeEnabled: Bool { false }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        cursorLock.lock(); defer { cursorLock.unlock() }
        let flag = CancellationFlag()
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return -1 }
        operation = flag; stateLock.unlock()
        defer { stateLock.lock(); operation = nil; stateLock.unlock() }
        do {
            let data = try source.read(offset: cursor, count: Int(size), interrupt: flag)
            guard !flag.cancelled else { return -1 }
            data.copyBytes(to: buffer, count: data.count)
            cursor += Int64(data.count)
            return Int32(data.count)
        } catch { return -1 }
    }
    func seek(offset: Int64, whence: Int32) -> Int64 {
        cursorLock.lock(); defer { cursorLock.unlock() }
        stateLock.lock(); let isClosed = closed; stateLock.unlock()
        guard !isClosed else { return -1 }
        let direction = whence & ~Int32(0x20000) // AVSEEK_FORCE
        if direction == 65536 { return source.size } // AVSEEK_SIZE
        let base: Int64
        switch direction {
        case 0: base = 0
        case 1: base = cursor
        case 2: base = source.size
        default: return -1
        }
        let (position, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, position >= 0 else { return -1 }
        cursor = position; return position
    }
    func cancel() {
        stateLock.lock(); let flag = operation; stateLock.unlock()
        flag?.cancel()
    }
    func close() {
        stateLock.lock(); closed = true; let flag = operation; stateLock.unlock()
        flag?.cancel()
    }
    func makeIndependentReader() -> (any IOReader)? {
        stateLock.lock(); let isClosed = closed; stateLock.unlock()
        return isClosed ? nil : AetherFileReader(source: source)
    }
}

/// AetherEngine backend; native sessions keep AVKit, software sessions use its public surface.
@MainActor
final class AetherMKVPlayback {
    let engine: AetherEngine
    var player: AVPlayer? { engine.currentAVPlayer }
    var usesSubtitleOverlay: Bool {
        if player == nil || styledSubtitles != nil { return true }
        guard let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else { return false }
        // FFmpeg reports decoder names (pgssub/dvdsub/dvbsub), while some
        // sources use descriptor names. Bitmap captions need the image overlay.
        let codec = track.codec.lowercased()
        return ["pgs", "hdmv", "dvb_sub", "dvbsub", "dvd_sub", "dvdsub", "vobsub"]
            .contains { codec.contains($0) }
    }
    let info: MediaInfo
    let styledSubtitles: StyledASSCoordinator?
    var onItemChanged: ((AVPlayer, AVPlayerItem) -> Void)?
    private var itemSubscription: AnyCancellable?
    private var stopped = false
    init(engine: AetherEngine, info: MediaInfo, enableStyledSubtitles: Bool = false) {
        self.engine = engine; self.info = info
        styledSubtitles = enableStyledSubtitles ? StyledASSCoordinator(engine: engine) : nil
        itemSubscription = engine.$currentAVPlayerItem.dropFirst().sink { [weak self] item in
            guard let self, let item, let player = self.engine.currentAVPlayer else { return }
            self.onItemChanged?(player, item)
        }
    }
    static func open(source: CachedRemoteFile, fileExtension: String) async throws -> AetherMKVPlayback {
        let formatHint: String? = fileExtension.lowercased() == "mkv" ? "matroska" : nil
        if CommandLine.arguments.contains("--aether-diagnostics") {
            EngineLog.handler = { print($0); fflush(stdout) }
        }
        let engine = try AetherEngine()
        engine.logTag = "BoraMin-Aether"
        engine.backgroundPlaybackEnabled = false
        var options = LoadOptions()
        options.autoplay = false
        options.displayCriteriaOwner = .avKit
        options.prepareNativeSubtitles = true
        options.forwardBufferSegments = 4
        options.sessionCacheByteBudget = 128 * 1024 * 1024
        return try await withTaskCancellationHandler {
            do {
                let probe = try await Task.detached(priority: .userInitiated) {
                    let reader = AetherFileReader(source: source)
                    defer { reader.close() }
                    return try AetherEngine.probe(source: .custom(reader, formatHint: formatHint))
                }.value
                try Task.checkCancellation()
                let styled = fileExtension.lowercased() == "mkv" && probe.subtitleTracks.contains { StyledASSCoordinator.isASS($0.codec) }
                options.preserveASSMarkup = styled
                // ASS files use source-track selection + our overlay, avoiding a second plain-text rendition.
                options.prepareNativeSubtitles = !styled
                let supported = probe.audioTracks.filter { ["aac", "ac3", "eac3", "alac", "mp3"].contains($0.codec.lowercased()) }
                let preferredAudio = (supported.first(where: { $0.isDefault }) ?? supported.first).map { Int32($0.id) }
                if let preferredAudio { print("BORAMIN_AETHER preferred native audio stream=\(preferredAudio)") }
                do {
                    try await engine.load(source: .custom(AetherFileReader(source: source), formatHint: formatHint), options: options, audioSourceStreamIndex: preferredAudio)
                    // load() can return before AVFoundation parses the first HLS segments.
                    // Keep startup readiness inside this catch so late configuration
                    // rejections use the same single retry on every platform.
                    if let item = engine.currentAVPlayer?.currentItem {
                        let deadline = ProcessInfo.processInfo.systemUptime + 30
                        while item.status == .unknown {
                            try Task.checkCancellation()
                            guard !source.cancellation.cancelled else { throw CancellationError() }
                            guard ProcessInfo.processInfo.systemUptime < deadline else {
                                throw PlayerError("Timed out waiting for native video playback to become ready.")
                            }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        if item.status == .failed {
                            throw item.error ?? PlayerError("The native player could not open this video.")
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                    let failure = error as NSError
                    let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                    // AVFoundation can reject a valid source configuration that the engine's
                    // alternate host supports (for example AAC with a Program Config Element).
                    // Reopen through the engine's public API once; SMB/network failures retain
                    // their original error and never trigger a decoder retry.
                    guard failure.domain == AVFoundationErrorDomain, failure.code == -11829,
                          underlying?.domain == "CoreMediaErrorDomain", underlying?.code == -12848 else { throw error }
                    print("BORAMIN_AETHER native configuration rejected; retrying alternate playback path")
                    options.preferredDecodePath = .software
                    try await engine.load(source: .custom(AetherFileReader(source: source), formatHint: formatHint), options: options, audioSourceStreamIndex: preferredAudio)
                }
                try Task.checkCancellation()
                if let item = engine.currentAVPlayer?.currentItem, item.status == .failed {
                    throw item.error ?? PlayerError("The native player could not open this video.")
                }
                if case .error(let message) = engine.state { throw PlayerError(message) }
                var info = MediaInfo()
                info.width = probe.videoWidth; info.height = probe.videoHeight
                info.duration = probe.durationSeconds; info.frame_rate = probe.videoFrameRate ?? 0
                info.vp9 = probe.videoCodecName == "vp9" ? 1 : 0
                switch probe.videoCodecName {
                case "h264": info.codec_type = kCMVideoCodecType_H264
                case "hevc": info.codec_type = kCMVideoCodecType_HEVC
                case "av1": info.codec_type = kCMVideoCodecType_AV1
                case "vp9": info.codec_type = kCMVideoCodecType_VP9
                default: break
                }
                print("BORAMIN_AETHER loaded native=\(engine.currentAVPlayer != nil)")
                return AetherMKVPlayback(engine: engine, info: info, enableStyledSubtitles: styled)
            } catch { engine.stop(); throw error }
        } onCancel: {
            source.cancellation.cancel()
            Task { @MainActor in engine.stop() }
        }
    }
    func selectSubtitle(index: Int) {
        if index < 0 { engine.clearSubtitle() }
        else { engine.selectSubtitleTrack(index: index) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; itemSubscription = nil; onItemChanged = nil
        styledSubtitles?.stop(); engine.stop()
    }
}

#endif
