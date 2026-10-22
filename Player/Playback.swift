import AVKit
import SwiftUI
import VideoToolbox
import AMSMB2

struct PlayerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum VP9Support {
    static let registered: Void = {
        if #available(iOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
    }()
}

// Keep the immutable playback payload opaque to SwiftUI's value comparison.
// Reflecting the imported C metadata followed by Swift arrays crashed
// AttributeGraph when a second full-screen player was presented on tvOS.
final class PreparedMedia: Identifiable {
    let id = UUID()
    let title: String
    let source: URL
    let timeline: URL
    let vp9: Bool
    let directory: URL
    let info: MediaInfo
    let streaming: StreamingSession?
    let keyframes: [Double]
    let positionKey: String?

    init(title: String, source: URL, timeline: URL, vp9: Bool, directory: URL,
         info: MediaInfo, streaming: StreamingSession?, keyframes: [Double], positionKey: String? = nil) {
        self.title = title; self.source = source; self.timeline = timeline
        self.vp9 = vp9; self.directory = directory; self.info = info
        self.streaming = streaming; self.keyframes = keyframes
        self.positionKey = positionKey
    }

    static func indexedKeyframes(_ reader: OpaquePointer) -> [Double] {
        let count = media_keyframes(reader, nil, 0)
        guard count > 0, count <= 1_000_000 else { return [] }
        var times = [Double](repeating: 0, count: Int(count))
        guard media_keyframes(reader, &times, count) == count else { return [] }
        return times
    }
    func seekTime(_ requested: Double) -> Double {
        guard vp9, requested.isFinite, !keyframes.isEmpty else { return requested }
        var lower = 0, upper = keyframes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if keyframes[middle] < requested { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return keyframes[0] }
        if lower == keyframes.count { return keyframes[lower - 1] }
        return requested - keyframes[lower - 1] <= keyframes[lower] - requested ? keyframes[lower - 1] : keyframes[lower]
    }

    static func stream(client: SMB2Manager, path: String, size: Int64, title: String, directory: URL, cancellation: CancellationFlag, positionKey: String? = nil) async throws -> Self {
        guard size > 0 else { throw PlayerError("This SMB file is empty or its size is unavailable.") }
        let source = SMBRemoteFile(client: client, path: path, size: size, cancellation: cancellation)
        let transport = try StreamingSession(source: source, fileExtension: (path as NSString).pathExtension)
        do {
            try await transport.start()
            let (info, keyframes) = try await Task.detached(priority: .userInitiated) {
                var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
                guard let reader = media_open_io(source.makeIO(), &info, &error, error.count) else {
                    if cancellation.cancelled { throw CancellationError() }
                    throw PlayerError("Read streaming media: \(String(cString: error))")
                }
                let keyframes = info.vp9 != 0 ? indexedKeyframes(reader) : []
                media_close(reader)
                if info.vp9 != 0 {
                    let session = try HardwareVideo.makeSession(HardwareVideo.makeFormat(info))
                    VTDecompressionSessionInvalidate(session)
                }
                return (info, keyframes)
            }.value
            if cancellation.cancelled { throw CancellationError() }
            if info.vp9 != 0 { try transport.configureAudio(duration: info.duration) }
            print("BORAMIN_STREAM ready; fetched \(source.fetchedBytes) of \(size) bytes before playback")
            return Self(title: title, source: transport.sourceURL, timeline: info.vp9 != 0 ? transport.audioURL : transport.sourceURL,
                vp9: info.vp9 != 0, directory: directory, info: info, streaming: transport, keyframes: keyframes, positionKey: positionKey)
        } catch {
            let userCancelled = cancellation.cancelled
            transport.stop()
            if userCancelled { throw CancellationError() }
            throw error
        }
    }

    static func prepare(source: URL, directory: URL, title: String, cancellation: CancellationFlag) throws -> Self {
        var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
        guard let reader = media_open(source.path, &info, &error, error.count) else {
            throw PlayerError("Read media: \(String(cString: error))")
        }
        let keyframes = info.vp9 != 0 ? indexedKeyframes(reader) : []
        media_close(reader)
        if info.vp9 == 0 { return Self(title: title, source: source, timeline: source, vp9: false, directory: directory, info: info, streaming: nil, keyframes: []) }
        // Fail before the lengthy audio preparation if this device cannot decode the source profile.
        let format = try HardwareVideo.makeFormat(info)
        let session = try HardwareVideo.makeSession(format)
        VTDecompressionSessionInvalidate(session)
        guard info.duration.isFinite, info.duration > 0 else { throw PlayerError("This VP9 file has no usable duration.") }
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let required = info.duration * 48_000 * 4 + 64 * 1_024 * 1_024
        guard Double(values.volumeAvailableCapacity ?? 0) > required else {
            throw PlayerError("VP9 audio preparation needs about \(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file)) of free temporary storage.")
        }
        let audio = directory.appendingPathComponent("timeline.caf")
        let status = media_audio(source.path, audio.path, { context in
            guard let context else { return 1 }
            return Unmanaged<CancellationFlag>.fromOpaque(context).takeUnretainedValue().cancelled ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque(), &error, error.count)
        if cancellation.cancelled { throw CancellationError() }
        guard status == 0 else { throw PlayerError("Prepare audio: \(String(cString: error))") }
        return Self(title: title, source: source, timeline: audio, vp9: true, directory: directory, info: info, streaming: nil, keyframes: keyframes)
    }
}

/// Video uses the AVPlayer item's timebase, so native pause, seek and rate changes drive both tracks.
final class HardwareVideo: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "BoraMin.VP9", qos: .userInitiated)
    private let lock = NSLock()
    private var stopped = false
    private var revision = 0
    private var seekTime = 0.0
    private var seekPending = false
    private var outputTime = -1.0
    var queuedTime: Double { lock.lock(); defer { lock.unlock() }; return outputTime }
    private let path: String
    private let remote: SMBRemoteFile?
    var failure: ((String) -> Void)?
    var firstFrame: (() -> Void)?

    init(path: String, remote: SMBRemoteFile? = nil) { self.path = path; self.remote = remote; layer.videoGravity = .resizeAspect }
    func start(timebase: CMTimebase) {
        layer.controlTimebase = timebase
        queue.async { [self] in
            do { try run() }
            catch is CancellationError { }
            catch {
                if remote?.cancellation.cancelled != true, (try? state()) != nil {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.remote?.cancellation.cancelled != true, (try? self.state()) != nil else { return }
                        self.failure?(error.localizedDescription)
                    }
                }
            }
        }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        let target = max(0, seconds)
        if seekPending && abs(seekTime - target) < 0.05 { return }
        revision += 1; seekTime = target; seekPending = true
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in layer.sampleBufferRenderer.flush(removingDisplayedImage: true) }
    }
    private func state() throws -> (Int, Double) {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw CancellationError() }
        return (revision, seekTime)
    }
    static func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw PlayerError("\(action): OSStatus \(status)") }
    }
    static func makeFormat(_ info: MediaInfo) throws -> CMVideoFormatDescription {
        guard ((info.profile == 0 && info.bit_depth == 8) || (info.profile == 2 && info.bit_depth == 10)),
              info.chroma == 0 || info.chroma == 1 else {
            throw PlayerError("MVP VP9 playback supports 8-bit Profile 0 and 10-bit Profile 2, 4:2:0.")
        }
        // vpcC full box, with the source's profile, depth, chroma and color signalling.
        let vpcc: [UInt8] = [1, 0, 0, 0, UInt8(info.profile), UInt8(info.level),
            UInt8(info.bit_depth << 4 | info.chroma << 1 | info.full_range), UInt8(info.primaries),
            UInt8(info.transfer), UInt8(info.matrix), 0, 0]
        var ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": Data(vpcc)]]
        if info.primaries == 9 { ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCVImageBufferColorPrimaries_ITU_R_2020 }
        else if info.primaries == 1 { ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCVImageBufferColorPrimaries_ITU_R_709_2 }
        if info.transfer == 16 { ext[kCMFormatDescriptionExtension_TransferFunction] = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ }
        else if info.transfer == 18 { ext[kCMFormatDescriptionExtension_TransferFunction] = kCVImageBufferTransferFunction_ITU_R_2100_HLG }
        else if info.transfer == 1 { ext[kCMFormatDescriptionExtension_TransferFunction] = kCVImageBufferTransferFunction_ITU_R_709_2 }
        if info.matrix == 9 { ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCVImageBufferYCbCrMatrix_ITU_R_2020 }
        else if info.matrix == 1 { ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCVImageBufferYCbCrMatrix_ITU_R_709_2 }
        var copy = info
        if info.has_mastering != 0 { ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = withUnsafeBytes(of: &copy.mastering) { Data($0) } }
        if info.has_light != 0 { ext[kCMFormatDescriptionExtension_ContentLightLevelInfo] = withUnsafeBytes(of: &copy.light) { Data($0) } }
        var format: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_VP9,
            width: info.width, height: info.height, extensions: ext as CFDictionary, formatDescriptionOut: &format), "Create VP9 format")
        guard let format else { throw PlayerError("No VP9 format returned.") }
        return format
    }
    static func makeSession(_ format: CMVideoFormatDescription) throws -> VTDecompressionSession {
        _ = VP9Support.registered
        var session: VTDecompressionSession?
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
                                   kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data]
        guard let vpcc = atoms?["vpcC"], vpcc.count >= 7 else { throw PlayerError("VP9 configuration is missing.") }
        let depth = vpcc[6] >> 4
        let fullRange = vpcc[6] & 1 != 0
        let pixels: OSType = depth == 10
            ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: pixels,
                kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session), "Open VP9 hardware decoder")
        guard let session else { throw PlayerError("No VP9 hardware session returned.") }
        var property: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &property)
        guard status == noErr, property?.takeRetainedValue() as? Bool == true else {
            VTDecompressionSessionInvalidate(session)
            throw PlayerError("VP9 hardware decoding was not confirmed on this device.")
        }
        print("BORAMIN_VP9 hardware confirmed")
        return session
    }
    private func run() throws {
        var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
        let opened = remote.map { media_open_io($0.makeIO(), &info, &error, error.count) } ?? media_open(path, &info, &error, error.count)
        guard let reader = opened else { throw PlayerError(String(cString: error)) }
        defer { media_close(reader) }
        let format = try Self.makeFormat(info)
        print("BORAMIN_VP9 format profile=\(info.profile) depth=\(info.bit_depth) level=\(info.level) \(info.width)x\(info.height)")
        var session = try Self.makeSession(format)
        defer { VTDecompressionSessionInvalidate(session) }
        var activeRevision = 0
        var queued = 0
        var decoded = 0
        var late = 0
        let diagnosticStarted = ProcessInfo.processInfo.systemUptime
        var announcedFirstFrame = false
        var observedClock: (time: Double, host: Double, rate: Double)?
        while true {
            let (revision, target) = try state()
            let current = layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? 0
            let host = ProcessInfo.processInfo.systemUptime
            let rate = layer.controlTimebase.map { CMTimebaseGetRate($0) } ?? 0
            let previousClock = observedClock
            observedClock = (current, host, rate)
            // Paused native seeks can change the timebase before AVPlayerItem's
            // time-jump notification arrives. Detect the discontinuity here too,
            // instead of decoding every intervening video packet to catch up.
            if revision == activeRevision, let previousClock,
               abs(current - previousClock.time - (host - previousClock.host) * previousClock.rate) > 1 {
                seek(to: current)
                continue
            }
            if revision != activeRevision {
                VTDecompressionSessionInvalidate(session)
                session = try Self.makeSession(format)
                layer.sampleBufferRenderer.flush(removingDisplayedImage: false)
                guard media_seek(reader, target) >= 0 else { throw PlayerError("Cannot seek in this VP9 file.") }
                print("BORAMIN_VP9 seek \(target)s")
                activeRevision = revision
            }
            var bytes: UnsafePointer<UInt8>?, count: Int32 = 0, key: Int32 = 0
            var pts = 0.0, duration = 0.0
            let result = media_packet(reader, &bytes, &count, &pts, &duration, &key)
            if result < 0 { throw PlayerError("Read VP9 packet: FFmpeg \(result)") }
            if result == 0 {
                try Self.check(VTDecompressionSessionFinishDelayedFrames(session), "Drain VP9")
                print("BORAMIN_VP9 reached EOF; decoded \(decoded), queued \(queued) hardware-decoded frames")
                while try state().0 == activeRevision { Thread.sleep(forTimeInterval: 0.02) }
                continue
            }
            while pts > (layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? current) + 0.4 {
                if try state().0 != activeRevision { break }
                Thread.sleep(forTimeInterval: 0.003)
            }
            if try state().0 != activeRevision { continue }
            try autoreleasepool {
                guard count > 0, let bytes else { throw PlayerError("Empty VP9 packet.") }
                var block: CMBlockBuffer?
                try Self.check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                    blockLength: Int(count), blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: Int(count), flags: 0, blockBufferOut: &block), "Allocate VP9 packet")
                guard let block else { throw PlayerError("No packet buffer.") }
                try Self.check(CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: Int(count)), "Copy VP9 packet")
                var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration > 0 ? duration : 1 / max(1, info.frame_rate), preferredTimescale: 60000),
                    presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 60000), decodeTimeStamp: .invalid)
                var size = Int(count), sample: CMSampleBuffer?
                try Self.check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "Create VP9 sample")
                guard let sample else { throw PlayerError("No compressed sample.") }
                var callbackError: Error?
                try Self.check(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [self] status, _, image, timestamp, _ in
                    do {
                        try Self.check(status, "Decode VP9")
                        guard let image, try state().0 == activeRevision else { return }
                        decoded += 1
                        if decoded % 300 == 0 {
                            print("BORAMIN_VP9 decoded=\(decoded) pts=\(timestamp.seconds)")
                            if CommandLine.arguments.contains("--vp9-diagnostics") {
                                print("BORAMIN_VP9_DECODE elapsed=\(ProcessInfo.processInfo.systemUptime - diagnosticStarted) decoded=\(decoded) queued=\(queued) late=\(late)")
                            }
                        }
                        let now = layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? 0
                        if timestamp.seconds + timing.duration.seconds < now { late += 1; return }
                        if let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] {
                            for (source, destination) in [
                                (kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimariesKey),
                                (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunctionKey),
                                (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrixKey),
                                (kCMFormatDescriptionExtension_MasteringDisplayColorVolume, kCVImageBufferMasteringDisplayColorVolumeKey),
                                (kCMFormatDescriptionExtension_ContentLightLevelInfo, kCVImageBufferContentLightLevelInfoKey)] {
                                if let value = extensions[source] { CVBufferSetAttachment(image, destination, value as CFTypeRef, .shouldPropagate) }
                            }
                        }
                        var imageFormat: CMVideoFormatDescription?
                        try Self.check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &imageFormat), "Create decoded format")
                        var output: CMSampleBuffer?, displayTiming = timing
                        displayTiming.presentationTimeStamp = timestamp
                        try Self.check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                            formatDescription: imageFormat!, sampleTiming: &displayTiming, sampleBufferOut: &output), "Create display sample")
                        while !layer.sampleBufferRenderer.isReadyForMoreMediaData {
                            if try state().0 != activeRevision { return }
                            if layer.sampleBufferRenderer.status == .failed { throw layer.sampleBufferRenderer.error ?? PlayerError("VP9 renderer failed.") }
                            Thread.sleep(forTimeInterval: 0.003)
                        }
                        if let output {
                            layer.sampleBufferRenderer.enqueue(output); queued += 1
                            lock.lock()
                            outputTime = timestamp.seconds
                            if self.revision == activeRevision && timestamp.seconds + timing.duration.seconds >= seekTime { seekPending = false }
                            lock.unlock()
                            if !announcedFirstFrame {
                                announcedFirstFrame = true
                                DispatchQueue.main.async { [weak self] in self?.firstFrame?() }
                            }
                        }
                    } catch { callbackError = error }
                }, "Submit VP9 packet")
                if let callbackError { throw callbackError }
            }
        }
    }
}

#if os(iOS)
@MainActor enum PlaybackOrientation {
    // Retain the landscape requirement if an outgoing and incoming player overlap.
    static var players: Set<UUID> = []
    static var supported: UIInterfaceOrientationMask {
        players.isEmpty ? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown) : .landscape
    }
}
#endif

#if os(tvOS) || os(iOS)
final class NativePlayerController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    private var video: HardwareVideo?
    private var readiness: NSKeyValueObservation?
    private var failureObservation: NSKeyValueObservation?
    private var jump: NSObjectProtocol?
    private var ended: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    #if os(tvOS)
    private var displayManager: AVDisplayManager?
    #endif
    private var startup: Task<Void, Never>?
    private var clockObserver: Any?
    private var exercise: Task<Void, Never>?
    private var audioLoader: StreamingAudioLoader?
    private var playbackObservation: NSKeyValueObservation?
    private var decodingLabel: UILabel?
    private var decodingLabelTask: Task<Void, Never>?
    private var debugPanel: UIView?
    private var debugLabel: UILabel?
    private var debugTimer: Timer?
    private var debugSampleTime = 0.0
    private var debugSampleBytes: Int64 = 0
    private var hardwareFrameReady = false
    private var showedDecodingLabel = false
    var onFailure: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    private var began = false
    private var stopped = false
    private var restoredPosition = false
    private var startedPlayback = false
    private var completedPlayback = false
    private var lastCheckpoint = 0.0
    private var lastDiagnostic = 0.0
    private var active: Bool { !stopped && media.streaming?.source.cancellation.cancelled != true }
    private let media: PreparedMedia
    #if os(iOS)
    private let orientationID = UUID()
    private weak var playbackScene: UIWindowScene?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var shouldAutorotate: Bool { true }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        requestLandscape()
    }
    private func requestLandscape() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let scene = view.window?.windowScene ?? presentingViewController?.view.window?.windowScene else { return }
        playbackScene = scene
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }
    private func restoreMenuOrientation() {
        PlaybackOrientation.players.remove(orientationID)
        guard PlaybackOrientation.players.isEmpty,
              let scene = playbackScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        // Reapply the supported menu orientations, letting UIKit follow the device again.
        let orientation = UIDevice.current.orientation
        let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscape :
            (orientation == .portraitUpsideDown && UIDevice.current.userInterfaceIdiom == .pad ? .portraitUpsideDown : .portrait)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
    #endif
    init(media: PreparedMedia) {
        self.media = media; super.init(nibName: nil, bundle: nil)
        #if os(iOS)
        PlaybackOrientation.players.insert(orientationID)
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        delegate = self
        #if os(iOS)
        // AVKit owns pinch-to-zoom for native video; each presentation starts fitted.
        // VP9's separate display layer retains its existing aspect-fit behavior.
        if !media.vp9 { videoGravity = .resizeAspect }
        #endif
        let item: AVPlayerItem
        if media.vp9, let streaming = media.streaming {
            do {
                let loader = try streaming.makeAudioLoader(); audioLoader = loader
                item = AVPlayerItem(asset: loader.makeAsset())
            } catch { onFailure?(error.localizedDescription); return }
        } else { item = AVPlayerItem(url: media.timeline) }
        item.preferredForwardBufferDuration = 3
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle; title.value = media.title as NSString
        item.externalMetadata = [title]
        player = AVPlayer(playerItem: item)
        if media.streaming != nil { player?.automaticallyWaitsToMinimizeStalling = false }
        clockObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, !self.stopped else { return }
            self.media.streaming?.updateClock(time.seconds)
            let now = ProcessInfo.processInfo.systemUptime
            if CommandLine.arguments.contains("--vp9-diagnostics"), now - self.lastDiagnostic >= 2 {
                self.lastDiagnostic = now
                print("BORAMIN_VP9_DIAG host=\(now) clock=\(time.seconds) rate=\(self.player?.rate ?? 0) control=\(self.player?.timeControlStatus.rawValue ?? -1) video=\(self.video?.queuedTime ?? -1) renderer=\(self.video?.layer.sampleBufferRenderer.status.rawValue ?? -1) fetched=\(self.media.streaming?.source.fetchedBytes ?? 0) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) cache=\(self.media.streaming?.source.cacheDiagnostic ?? "local")")
            }
            if now - self.lastCheckpoint >= 15 {
                self.savePosition()
                self.lastCheckpoint = now
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.savePosition()
        }
        ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                print("BORAMIN_NATIVE playback reached end")
                guard let self, self.active, !self.completedPlayback else { return }
                self.completedPlayback = true
                if let key = self.media.positionKey { PlaybackPositions.shared.clear(key) }
                // Dismiss the existing full-screen presentation, preserving browser navigation.
                self.onDismiss?()
            }
        }
        if media.vp9 {
            let video = HardwareVideo(path: media.source.path, remote: media.streaming?.source)
            video.failure = { [weak self] message in
                guard let self, self.active else { return }
                print("BORAMIN_ERROR \(message)"); self.player?.pause(); self.onFailure?(message)
            }
            self.video = video
            video.firstFrame = { [weak self] in
                self?.hardwareFrameReady = true
                self?.showDecodingLabelIfPlaying()
            }
            contentOverlayView?.layer.addSublayer(video.layer)
            jump = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
                self?.media.streaming?.updateClock(item.currentTime().seconds)
                self?.video?.seek(to: item.currentTime().seconds)
            }
        }
        installDebugInfo()
        readiness = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                if item.status == .failed {
                    print("BORAMIN_NATIVE_ERROR \(item.error?.localizedDescription ?? "Playback failed.")")
                    print("BORAMIN_NATIVE_ERROR_DETAILS \(String(reflecting: item.error)) log=\(String(reflecting: item.errorLog()?.events))")
                    self.onFailure?(item.error?.localizedDescription ?? "Playback failed.")
                }
                guard item.status == .readyToPlay, !self.began else { return }
                print("BORAMIN_NATIVE ready to play")
                self.began = true
                self.startup = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.video != nil {
                        // Let the controller appear and Match Content settle before starting its clock.
                        try? await Task.sleep(for: .milliseconds(750))
                        let deadline = Date().addingTimeInterval(6)
                        #if os(tvOS)
                        while self.displayManager?.isDisplayModeSwitchInProgress == true && Date() < deadline && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        #endif
                        guard !Task.isCancelled else { return }
                    }
                    guard !Task.isCancelled, self.active else { return }
                    await self.restorePosition()
                    guard !Task.isCancelled, self.active else { return }
                    if let video = self.video {
                        guard let timebase = item.timebase else { self.onFailure?("Player timeline unavailable."); return }
                        if item.currentTime().seconds > 0 { video.seek(to: item.currentTime().seconds) }
                        video.start(timebase: timebase)
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                    guard !Task.isCancelled else { return }
                    self.player?.play()
                    if CommandLine.arguments.contains("--exercise-stream-controls") {
                        self.exercise = Task { @MainActor [weak self] in await self?.exerciseStreamingControls() }
                    } else if CommandLine.arguments.contains("--exercise-resume-completion") {
                        self.exercise = Task { @MainActor [weak self] in await self?.exerciseResumeCompletion() }
                    }
                }
            }
        }
        failureObservation = player?.observe(\.status, options: [.new]) { [weak self] player, _ in
            if player.status == .failed {
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    self.onFailure?(player.error?.localizedDescription ?? "Player failed.")
                }
            }
        }
        playbackObservation = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                if self.player?.timeControlStatus == .playing { self.startedPlayback = true }
                else if self.player?.timeControlStatus == .paused && self.startedPlayback {
                    self.savePosition()
                    NotificationCenter.default.post(name:Notification.Name("BoraMinPlaybackSync"),object:nil)
                }
                self.showDecodingLabelIfPlaying()
            }
        }
    }
    private func restorePosition() async {
        guard let key = media.positionKey,
              let saved = PlaybackPositions.shared.position(for: key, duration: media.info.duration), let player else {
            restoredPosition = true; return
        }
        // Start at the preceding VP9 keyframe so resuming never skips unwatched
        // content and doesn't require decoding a long preroll after audio starts.
        let target = media.vp9 && !media.keyframes.isEmpty ? (media.keyframes.last { $0 <= saved } ?? 0) : saved
        let success = await player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        guard !Task.isCancelled, active else { return }
        if success {
            print("BORAMIN_RESUME restored saved=\(saved)s target=\(target)s")
        } else {
            PlaybackPositions.shared.clear(key)
            _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        restoredPosition = true
    }
    private func savePosition() {
        guard !completedPlayback, restoredPosition, startedPlayback, let key = media.positionKey, let player,
              player.currentItem?.status == .readyToPlay else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        PlaybackPositions.shared.save(seconds, duration: media.info.duration, for: key)
        print("BORAMIN_RESUME saved \(seconds)s")
    }
    #if os(iOS)
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard !context.isCancelled else { return }
            self?.onDismiss?()
        }
    }
    #endif
    override func viewWillDisappear(_ animated: Bool) {
        if isBeingDismissed || parent?.isBeingDismissed == true { player?.pause() }
        savePosition()
        NotificationCenter.default.post(name:Notification.Name("BoraMinPlaybackSync"),object:nil)
        super.viewWillDisappear(animated)
    }
    private func installDebugInfo() {
        guard UserDefaults.standard.bool(forKey: "showDebugInfo"), let overlay = contentOverlayView else { return }
        let panel = UIView()
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        panel.isUserInteractionEnabled = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        overlay.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            panel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: panel.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: panel.layoutMarginsGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: panel.layoutMarginsGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: panel.layoutMarginsGuide.bottomAnchor)
        ])
        debugPanel = panel; debugLabel = label
        debugSampleTime = ProcessInfo.processInfo.systemUptime
        debugSampleBytes = media.streaming?.source.fetchedBytes ?? 0
        updateDebugInfo(now: debugSampleTime, initial: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.updateDebugInfo(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        debugTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func updateDebugInfo(now: Double, initial: Bool = false) {
        guard let label = debugLabel, initial || now - debugSampleTime >= 1 else { return }
        let network: String
        let cache: String
        if let source = media.streaming?.source {
            let metrics = source.transferMetrics
            let rate = initial ? 0 : Double(max(0, metrics.fetched - debugSampleBytes)) / max(0.001, now - debugSampleTime) / 1_000_000
            network = String(format: "Network: %.2f MB/s", rate)
            cache = String(format: "Cache: %.1f / %.0f MiB", Double(metrics.cached) / 1_048_576, Double(metrics.capacity) / 1_048_576)
            debugSampleBytes = metrics.fetched
        } else {
            network = "Network: Local file"
            cache = "Cache: Not applicable"
        }
        let resolution = media.info.width > 0 && media.info.height > 0 ? "\(media.info.width) × \(media.info.height)" : "Unknown"
        let fps = media.info.frame_rate > 0 ? String(format: "%.2f fps", media.info.frame_rate) : "fps unknown"
        let decoder = media.vp9 ? "Hardware Decoding" : "System Decoding (HW/SW unknown)"
        label.text = [network, cache, "Video: \(resolution), \(fps)", "Decoder: \(decoder)"].joined(separator: "\n")
        debugSampleTime = now
    }
    private func showDecodingLabelIfPlaying() {
        guard active, !showedDecodingLabel, player?.timeControlStatus == .playing,
              !media.vp9 || hardwareFrameReady, let overlay = contentOverlayView else { return }
        // Only our VideoToolbox session reports actual HW/SW selection. AVPlayer
        // does not expose it; never infer hardware use from codec capability.
        let text = media.vp9 ? "Hardware Decoding" : "System Decoding (HW/SW unknown)"
        showedDecodingLabel = true
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isOpaque = false
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 32)
        ])
        decodingLabel = label
        let shownAt = ProcessInfo.processInfo.systemUptime
        print("BORAMIN_DECODING shown: \(text)")
        decodingLabelTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.decodingLabel?.removeFromSuperview(); self.decodingLabel = nil
            print("BORAMIN_DECODING hidden after \(ProcessInfo.processInfo.systemUptime - shownAt)s")
        }
    }
    private func exerciseResumeCompletion() async {
        guard let player, let key = media.positionKey else { return }
        do {
            try await Task.sleep(for: .seconds(2))
            _ = await player.seek(to: CMTime(seconds: max(0, media.info.duration - 0.5), preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            for _ in 0..<200 {
                if completedPlayback { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard completedPlayback, PlaybackPositions.shared.progress(for: key) == nil else {
                throw PlayerError("Completion did not clear the saved position.")
            }
            savePosition()
            guard PlaybackPositions.shared.progress(for: key) == nil else { throw PlayerError("Completion bookmark was recreated.") }
            print("BORAMIN_RESUME PASS: native completion cleared the bookmark and subsequent saves kept it cleared")
        } catch is CancellationError { }
        catch { print("BORAMIN_RESUME TEST FAILED: \(error.localizedDescription)") }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); video?.layer.frame = contentOverlayView?.bounds ?? view.bounds }
    #if os(tvOS)
    func playerViewController(_ playerViewController: AVPlayerViewController, timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
        let seconds = media.seekTime(targetTime.seconds)
        if media.vp9 { video?.seek(to: seconds) }
        print("BORAMIN_NATIVE seek requested=\(targetTime.seconds) keyframe=\(seconds)")
        return CMTime(seconds: seconds, preferredTimescale: 60000)
    }
    #endif
    private func exerciseStreamingControls() async {
        guard let player, let stream = media.streaming else { return }
        do {
            try await Task.sleep(for: .seconds(6))
            player.pause()
            let before = stream.source.fetchedBytes
            try await Task.sleep(for: .seconds(2))
            print("BORAMIN_STREAM pause test at \(player.currentTime().seconds)s; extra reads \(stream.source.fetchedBytes - before)")
            for (requested, paused) in [(90.0, false), (20.0, false), (60.0, true)] {
                try Task.checkCancellation()
                let seconds = media.seekTime(requested)
                let seekStarted = ProcessInfo.processInfo.systemUptime
                if paused { player.pause() }
                var completed: Bool?
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { success in
                    print("BORAMIN_STREAM native seek callback \(seconds)s completed=\(success)")
                    DispatchQueue.main.async { completed = success }
                }
                if !paused { player.play() }
                var positioned = false
                for _ in 0..<300 {
                    let time = player.currentTime().seconds
                    if completed == true, abs(time - seconds) < 3,
                       self.video.map({ $0.queuedTime >= seconds && abs($0.queuedTime - time) < 1 }) ?? true {
                        positioned = true; break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard positioned else { throw PlayerError("Seek test failed at \(seconds)s: clock=\(player.currentTime().seconds), video=\(self.video?.queuedTime ?? -1)") }
                let readyAfter = ProcessInfo.processInfo.systemUptime - seekStarted
                let start = player.currentTime().seconds
                try await Task.sleep(for: .seconds(2))
                let advanced = player.currentTime().seconds - start
                guard paused ? abs(advanced) < 0.1 : advanced > 1 else { throw PlayerError("Seek test stalled after \(seconds)s") }
                print("BORAMIN_STREAM PASS seek requested=\(requested) keyframe=\(seconds)s readyAfter=\(readyAfter)s paused=\(paused) clock=\(player.currentTime().seconds) video=\(self.video?.queuedTime ?? -1); SMB fetched \(stream.source.fetchedBytes)")
                if paused { player.play() }
            }
            print("BORAMIN_STREAM controls test finished at \(player.currentTime().seconds)s; SMB fetched \(stream.source.fetchedBytes)/\(stream.source.size)")
        } catch is CancellationError { }
        catch { print("BORAMIN_STREAM TEST FAILED: \(error.localizedDescription)") }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        requestLandscape()
        #endif
        #if os(tvOS)
        guard media.vp9 else { return }
        let info = media.info
        if let format = try? HardwareVideo.makeFormat(info) {
            displayManager = view.window?.avDisplayManager
            displayManager?.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(info.frame_rate), formatDescription: format)
        }
        #endif
    }
    func stop() {
        guard !stopped else { return }
        savePosition()
        NotificationCenter.default.post(name:Notification.Name("BoraMinPlaybackSync"),object:nil)
        stopped = true
        #if os(iOS)
        restoreMenuOrientation()
        #endif
        startup?.cancel(); startup = nil
        decodingLabelTask?.cancel(); decodingLabelTask = nil
        decodingLabel?.removeFromSuperview(); decodingLabel = nil
        debugPanel?.removeFromSuperview(); debugPanel = nil; debugLabel = nil
        debugTimer?.invalidate(); debugTimer = nil
        playbackObservation = nil
        exercise?.cancel(); exercise = nil
        player?.pause(); video?.stop(); player?.replaceCurrentItem(with: nil)
        video?.layer.removeFromSuperlayer(); video = nil
        audioLoader?.stop(); audioLoader = nil
        if let clockObserver { player?.removeTimeObserver(clockObserver); self.clockObserver = nil }
        media.streaming?.stop()
        if let jump { NotificationCenter.default.removeObserver(jump); self.jump = nil }
        if let ended { NotificationCenter.default.removeObserver(ended); self.ended = nil }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver); self.backgroundObserver = nil }
        #if os(tvOS)
        displayManager?.preferredDisplayCriteria = nil
        #endif
        readiness = nil; failureObservation = nil
        player = nil
    }
    deinit {
        debugTimer?.invalidate()
        decodingLabelTask?.cancel()
        if let jump { NotificationCenter.default.removeObserver(jump) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        video?.stop()
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let media: PreparedMedia
    let failure: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> NativePlayerController {
        let controller = NativePlayerController(media: media)
        controller.onFailure = failure; controller.onDismiss = { dismiss() }
        return controller
    }
    func updateUIViewController(_ controller: NativePlayerController, context: Context) { }
    static func dismantleUIViewController(_ controller: NativePlayerController, coordinator: ()) { controller.stop() }
}
#endif
