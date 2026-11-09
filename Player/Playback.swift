import AudioToolbox
import Combine
import OSLog
import AVKit
import SwiftUI
import VideoToolbox
import AMSMB2

private let playbackLog = Logger(subsystem: BoraMinIdentity.bundleIdentifier, category: "Playback")

struct PlayerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Select through AVFoundation; AVKit continues to own the audio menu.
@MainActor enum NativeAudioSelection {
    static func decoderIDs() -> Set<AudioFormatID> {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        let status = ids.withUnsafeMutableBytes { AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? Set(ids) : []
    }
    static func selectFirstSupported(in item: AVPlayerItem) async throws {
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return } // Silent video is valid.
        let decoders = decoderIDs()
        guard !decoders.isEmpty else { throw PlayerError("Unable to determine supported audio formats on this device.") }
        if let group = try await item.asset.loadMediaSelectionGroup(for: .audible) {
            let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
            if let option = playable.first(where: { option in
                option.mediaSubTypes.contains { decoders.contains($0.uint32Value) }
            }) {
                item.select(option, in: group)
                playbackLog.notice("Selected supported audio codec=\(option.mediaSubTypes.first?.uint32Value ?? 0)")
                return
            }
        } else {
            // Single-track assets may not expose a selection group.
            for track in tracks {
                let formats = try await track.load(.formatDescriptions)
                if formats.contains(where: { decoders.contains(CMFormatDescriptionGetMediaSubType($0)) }) { return }
            }
        }
        throw PlayerError("None of this video's audio tracks are supported on this device.")
    }
}

/// Sample only while the debug overlay is visible. CPU 100% means one core.
@MainActor final class PlaybackDebugStats {
    private var previousCPU: Double?
    private var previousTime: Double?
    private var frames = "Frames (dropped/total): ?"
    private var loading = false
    func lines(item: AVPlayerItem?, video: HardwareVideo?) -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = media_process_cpu_seconds()
        var cpuText = "CPU (app): Unavailable"
        if cpu >= 0, let old = previousCPU, let time = previousTime, now > time, cpu >= old {
            cpuText = String(format: "CPU (app): %.1f%%", (cpu - old) / (now - time) * 100)
        }
        previousCPU = cpu >= 0 ? cpu : nil; previousTime = now
        if let video {
            if !loading {
                loading = true
                video.layer.sampleBufferRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
                    let text = metrics.map { "Frames (dropped/total): \($0.numberOfDroppedFrames)/\($0.totalNumberOfFrames)" } ?? "Frames (dropped/total): ?"
                    Task { @MainActor [weak self] in self?.frames = text; self?.loading = false }
                }
            }
        } else {
            let events = item?.accessLog()?.events ?? []
            let values = events.map(\.numberOfDroppedVideoFrames)
            let dropped = !values.isEmpty && values.allSatisfy { $0 >= 0 } ? String(values.reduce(0, +)) : "?"
            frames = "Frames (dropped/total): \(dropped)/?"
        }
        let bytes = media_process_resident_bytes()
        return [frames, cpuText, bytes > 0 ? String(format: "Memory (app): %.1f MiB", Double(bytes) / 1048576) : "Memory (app): Unavailable"]
    }
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    func cancel() {
        lock.lock(); value = true
        let callbacks = Array(handlers.values); handlers.removeAll(); lock.unlock()
        callbacks.forEach { $0() }
    }
    /// HTTP header probes can be cancelled by the same flag as blocking media reads.
    func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if value { lock.unlock(); handler() }
        else { handlers[id] = handler; lock.unlock() }
        return id
    }
    func removeHandler(_ id: UUID) { lock.lock(); handlers.removeValue(forKey: id); lock.unlock() }
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
    let usesSampleBufferVideo: Bool
    let directory: URL
    let info: MediaInfo
    let streaming: StreamingSession?
    let keyframes: [Double]
    let positionKey: String?
    @MainActor var audioSelection: SavedTrackSelection?
    @MainActor var subtitleSelection: SavedSubtitleSelection?
    let videoFormat: CMVideoFormatDescription?

    init(title: String, source: URL, timeline: URL, usesSampleBufferVideo: Bool, directory: URL,
         info: MediaInfo, streaming: StreamingSession?, keyframes: [Double], positionKey: String? = nil, videoFormat: CMVideoFormatDescription? = nil) {
        self.title = title; self.source = source; self.timeline = timeline
        self.usesSampleBufferVideo = usesSampleBufferVideo; self.directory = directory; self.info = info
        self.streaming = streaming; self.keyframes = keyframes
        self.positionKey = positionKey
        self.videoFormat = videoFormat
    }

    static func indexedKeyframes(_ reader: OpaquePointer) -> [Double] {
        let count = media_keyframes(reader, nil, 0)
        guard count > 0, count <= 1_000_000 else { return [] }
        var times = [Double](repeating: 0, count: Int(count))
        guard media_keyframes(reader, &times, count) == count else { return [] }
        return times
    }
    static func configuration(_ reader: OpaquePointer) throws -> Data {
        var bytes: UnsafePointer<UInt8>?
        let count = media_video_configuration(reader, &bytes)
        guard count >= 0 else { throw PlayerError("Invalid video decoder configuration.") }
        guard count > 0, let bytes else { return Data() }
        return Data(bytes: bytes, count: Int(count))
    }
    static func needsDemuxedPlayback(_ info: MediaInfo, fileExtension: String) -> Bool {
        info.vp9 != 0 || ["mkv", "webm"].contains(fileExtension.lowercased())
    }
    @discardableResult static func validateDecoder(_ info: MediaInfo, configuration: Data) throws -> CMVideoFormatDescription {
        let format = try HardwareVideo.makeFormat(info, configuration: configuration)
        if info.vp9 != 0 {
            let session = try HardwareVideo.makeSession(format)
            VTDecompressionSessionInvalidate(session)
        } else {
            if info.codec_type == kCMVideoCodecType_AV1 {
                if #available(iOS 26.2, macOS 11.0, tvOS 26.2, *) {
                    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
                }
            }
            var session: VTDecompressionSession?
            try HardwareVideo.check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), "Open system video decoder")
            if let session { VTDecompressionSessionInvalidate(session) }
        }
        return format
    }
    func seekTime(_ requested: Double) -> Double {
        guard usesSampleBufferVideo, requested.isFinite, !keyframes.isEmpty else { return requested }
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
        try await stream(session: RemoteSession(smb: client), path: path, size: size, title: title, directory: directory, cancellation: cancellation, positionKey: positionKey)
    }
    static func stream(session: RemoteSession, path: String, size: Int64, title: String, directory: URL, cancellation: CancellationFlag, positionKey: String? = nil) async throws -> Self {
        guard size > 0 else { throw PlayerError("This file is empty or its size is unavailable.") }
        let source = try await session.openFile(path: path, size: size, cancellation: cancellation)
        let ext = (path as NSString).pathExtension
        let alwaysUseAether = UserDefaults.standard.object(forKey: PlaybackRoute.alwaysUseAetherKey) as? Bool
            ?? PlaybackRoute.defaultAlwaysUseAether
        let usesDirectProbe = ["mp4", "m4v", "mov", "webm"].contains(ext.lowercased())
        let transport = try StreamingSession(source: source, fileExtension: (path as NSString).pathExtension)
        do {
            try await transport.start()
            let subtitles = await ExternalSubtitles.discover(session: session, path: path, playbackCancellation: cancellation)
            await transport.setExternalSubtitles(subtitles)
            guard !cancellation.cancelled else { throw CancellationError() }
            // Check for VP9 before opening an AetherEngine container. If the legacy
            // probe cannot identify the stream, leave that container to AetherEngine.
            let usesHardwareVP9: Bool
            if !usesDirectProbe && (ext.lowercased() == "mkv" || alwaysUseAether) {
                usesHardwareVP9 = try await Task.detached(priority: .userInitiated) {
                    var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
                    guard let reader = media_open_io(source.makeIO(), &info, &error, error.count) else {
                        if cancellation.cancelled { throw CancellationError() }
                        return false
                    }
                    defer { media_close(reader) }
                    return info.vp9 != 0
                }.value
            } else { usesHardwareVP9 = false }
            guard !cancellation.cancelled else { throw CancellationError() }
            if !usesHardwareVP9 && !usesDirectProbe {
                let timeline = try await transport.configureAetherPlayback(forceBoraMinUI: alwaysUseAether, positionKey: positionKey)
                guard !cancellation.cancelled else { throw CancellationError() }
                guard let info = await transport.aetherMediaInfo else { throw PlayerError("AetherEngine did not provide media information.") }
                return Self(title: title, source: transport.sourceURL, timeline: timeline, usesSampleBufferVideo: false,
                            directory: directory, info: info, streaming: transport, keyframes: [], positionKey: positionKey)
            }
            let (info, keyframes, format) = try await Task.detached(priority: .userInitiated) {
                var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
                guard let reader = media_open_io(source.makeIO(), &info, &error, error.count) else {
                    if cancellation.cancelled { throw CancellationError() }
                    throw PlayerError("Read streaming media: \(String(cString: error))")
                }
                defer { media_close(reader) }
                let aetherContainer = info.vp9 == 0 && (alwaysUseAether || ext.lowercased() == "webm")
                let demuxed = needsDemuxedPlayback(info, fileExtension: ext) && !aetherContainer
                let format = demuxed ? try validateDecoder(info, configuration: configuration(reader)) : nil
                let keyframes = demuxed ? indexedKeyframes(reader) : []
                return (info, keyframes, format)
            }.value
            if cancellation.cancelled { throw CancellationError() }
            if info.vp9 == 0 && (alwaysUseAether || ext.lowercased() == "webm") {
                let timeline = try await transport.configureAetherPlayback(forceBoraMinUI: alwaysUseAether, positionKey: positionKey)
                if cancellation.cancelled { throw CancellationError() }
                playbackLog.notice("AetherEngine container streaming enabled")
                return Self(title: title, source: transport.sourceURL, timeline: timeline, usesSampleBufferVideo: false,
                            directory: directory, info: info, streaming: transport, keyframes: [], positionKey: positionKey)
            }
            if usesHardwareVP9 && ext.lowercased() == "mkv" { playbackLog.notice("VP9 MKV using original hardware decoder and native AVKit controls") }
            let demuxed = needsDemuxedPlayback(info, fileExtension: ext)
            if demuxed { try transport.configureAudio(duration: info.duration) }
            playbackLog.notice("BORAMIN_STREAM ready; fetched \(source.fetchedBytes) of \(size) bytes before playback")
            return Self(title: title, source: transport.sourceURL, timeline: demuxed ? transport.audioURL : transport.sourceURL,
                usesSampleBufferVideo: demuxed, directory: directory, info: info, streaming: transport, keyframes: keyframes, positionKey: positionKey, videoFormat: format)
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
        defer { media_close(reader) }
        let demuxed = needsDemuxedPlayback(info, fileExtension: source.pathExtension)
        let keyframes = demuxed ? indexedKeyframes(reader) : []
        if !demuxed { return Self(title: title, source: source, timeline: source, usesSampleBufferVideo: false, directory: directory, info: info, streaming: nil, keyframes: []) }
        // Fail before the lengthy audio preparation if this device cannot decode the source profile.
        let format = try validateDecoder(info, configuration: configuration(reader))
        guard info.duration.isFinite, info.duration > 0 else { throw PlayerError("This file has no usable duration.") }
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let required = info.duration * 48_000 * 4 + 64 * 1_024 * 1_024
        guard Double(values.volumeAvailableCapacity ?? 0) > required else {
            throw PlayerError("Audio preparation needs about \(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file)) of free temporary storage.")
        }
        let audio = directory.appendingPathComponent("timeline.caf")
        let status = media_audio(source.path, audio.path, { context in
            guard let context else { return 1 }
            return Unmanaged<CancellationFlag>.fromOpaque(context).takeUnretainedValue().cancelled ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque(), &error, error.count)
        if cancellation.cancelled { throw CancellationError() }
        guard status == 0 else { throw PlayerError("Prepare audio: \(String(cString: error))") }
        return Self(title: title, source: source, timeline: audio, usesSampleBufferVideo: true, directory: directory, info: info, streaming: nil, keyframes: keyframes, videoFormat: format)
    }
}

/// CoreMedia format descriptions for codecs carried by Matroska. No pixel decoding in FFmpeg.
enum NativeVideoFormat {
    static func colorExtensions(_ info: MediaInfo) -> [CFString: Any] {
        var ext: [CFString: Any] = [:]
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
        return ext
    }
    static func make(_ info: MediaInfo, configuration: Data) throws -> CMVideoFormatDescription {
        guard info.codec_type != 0 else { throw PlayerError("This MKV video codec has no supported system decoder integration.") }
        let ext = colorExtensions(info)
        if info.codec_type == kCMVideoCodecType_H264 || info.codec_type == kCMVideoCodecType_HEVC {
            return try parameterSetFormat(info.codec_type, configuration: configuration, extensions: ext)
        }
        var extensions = ext
        if info.codec_type == kCMVideoCodecType_AV1 {
            guard configuration.count >= 4, configuration[0] == 0x81 else { throw PlayerError("Invalid AV1 codec configuration.") }
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["av1C": configuration]
        } else if info.codec_type == kCMVideoCodecType_MPEG4Video {
            guard !configuration.isEmpty else { throw PlayerError("MPEG-4 video configuration is missing.") }
            func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
                let n = payload.count
                return [tag, UInt8((n >> 21) & 127) | 128, UInt8((n >> 14) & 127) | 128,
                        UInt8((n >> 7) & 127) | 128, UInt8(n & 127)] + payload
            }
            let config = descriptor(4, [0x20, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + descriptor(5, Array(configuration)))
            let esds = [UInt8](repeating: 0, count: 4) + descriptor(3, [0, 1, 0] + config + descriptor(6, [2]))
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["esds": Data(esds)]
        } else if info.codec_type == 0x76703038 { // vp08
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["vpcC": Data([1,0,0,0,0,10,0x82,2,2,2,0,0])]
        }
        var format: CMVideoFormatDescription?
        try HardwareVideo.check(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: info.codec_type,
            width: info.width, height: info.height, extensions: extensions as CFDictionary, formatDescriptionOut: &format), "Create system video format")
        guard let format else { throw PlayerError("No system video format returned.") }
        return format
    }
    private static func parameterSetFormat(_ codec: CMVideoCodecType, configuration: Data, extensions: [CFString: Any]) throws -> CMVideoFormatDescription {
        let bytes = Array(configuration)
        var offset = 0, ranges: [Range<Int>] = []
        func byte() throws -> Int {
            guard offset < bytes.count else { throw PlayerError("Truncated video codec configuration.") }
            defer { offset += 1 }; return Int(bytes[offset])
        }
        func word() throws -> Int { let high = try byte(); return try (high << 8) | byte() }
        func nal(keep: Bool = true) throws {
            let size = try word()
            guard size > 0, size <= bytes.count - offset else { throw PlayerError("Invalid video parameter set length.") }
            if keep { ranges.append(offset..<offset + size) }
            offset += size
        }
        guard try byte() == 1 else { throw PlayerError("Unsupported video codec configuration version.") }
        let length: Int
        if codec == kCMVideoCodecType_H264 {
            offset = 4; length = try (byte() & 3) + 1
            let spsCount = try byte() & 31
            for _ in 0..<spsCount { try nal() }
            let ppsCount = try byte()
            for _ in 0..<ppsCount { try nal() }
        } else {
            offset = 21; length = try (byte() & 3) + 1
            let arrays = try byte()
            for _ in 0..<arrays {
                let type = try byte() & 63
                let count = try word()
                for _ in 0..<count { try nal(keep: [32, 33, 34].contains(type)) }
            }
        }
        guard [1, 2, 4].contains(length), !ranges.isEmpty else { throw PlayerError("Video parameter sets are missing or invalid.") }
        return try configuration.withUnsafeBytes { storage in
            let base = storage.bindMemory(to: UInt8.self).baseAddress!
            let pointers = ranges.map { base.advanced(by: $0.lowerBound) }
            let sizes = ranges.map(\.count)
            var format: CMVideoFormatDescription?
            let status = pointers.withUnsafeBufferPointer { pointers in
                sizes.withUnsafeBufferPointer { sizes in
                    if codec == kCMVideoCodecType_H264 {
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                            parameterSetCount: pointers.count, parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!,
                            nalUnitHeaderLength: Int32(length), formatDescriptionOut: &format)
                    }
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count, parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: Int32(length), extensions: extensions as CFDictionary, formatDescriptionOut: &format)
                }
            }
            try HardwareVideo.check(status, "Create H.264/HEVC video format")
            guard let format else { throw PlayerError("No H.264/HEVC format returned.") }
            return format
        }
    }
}

/// Video uses the AVPlayer item's timebase, so native pause, seek and rate changes drive both tracks.
final class HardwareVideo: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "BoraMin.Video", qos: .userInitiated)
    private let lock = NSLock()
    private var stopped = false
    private var revision = 0
    private var seekTime = 0.0
    private var seekPending = false
    private var outputTime = -1.0
    var queuedTime: Double { lock.lock(); defer { lock.unlock() }; return outputTime }
    private let path: String
    private let remote: CachedRemoteFile?
    var failure: ((String) -> Void)?
    var firstFrame: (() -> Void)?

    init(path: String, remote: CachedRemoteFile? = nil) { self.path = path; self.remote = remote; layer.videoGravity = .resizeAspect }
    func logPerformance(sessionID: UUID) {
        let session = sessionID.uuidString
        let queued = queuedTime
        let clock = layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? 0
        let renderer = layer.sampleBufferRenderer
        let status = renderer.status.rawValue
        let ready = renderer.isReadyForMoreMediaData
        renderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics else {
                playbackLog.info("Video metrics unavailable session=\(session, privacy: .public) renderer=\(status)")
                return
            }
            playbackLog.notice("Video metrics session=\(session, privacy: .public) frames=\(metrics.totalNumberOfFrames) dropped=\(metrics.numberOfDroppedFrames) corrupted=\(metrics.numberOfCorruptedFrames) accumulatedDelaySeconds=\(metrics.totalAccumulatedFrameDelay) optimizedFrames=\(metrics.numberOfFramesDisplayedUsingOptimizedCompositing) queuedPTS=\(queued) clock=\(clock) renderer=\(status) readyForMore=\(ready)")
        }
    }
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
        if status != noErr {
            playbackLog.error("Decoder operation failed action=\(action, privacy: .public) OSStatus=\(status)")
            throw PlayerError("\(action): OSStatus \(status)")
        }
    }
    static func makeFormat(_ info: MediaInfo, configuration: Data = Data()) throws -> CMVideoFormatDescription {
        if info.vp9 == 0 { return try NativeVideoFormat.make(info, configuration: configuration) }
        guard ((info.profile == 0 && info.bit_depth == 8) || (info.profile == 2 && info.bit_depth == 10)),
              info.chroma == 0 || info.chroma == 1 else {
            throw PlayerError("MVP VP9 playback supports 8-bit Profile 0 and 10-bit Profile 2, 4:2:0.")
        }
        // vpcC full box, with the source's profile, depth, chroma and color signalling.
        let vpcc: [UInt8] = [1, 0, 0, 0, UInt8(info.profile), UInt8(info.level),
            UInt8(info.bit_depth << 4 | info.chroma << 1 | info.full_range), UInt8(info.primaries),
            UInt8(info.transfer), UInt8(info.matrix), 0, 0]
        var ext = NativeVideoFormat.colorExtensions(info)
        ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["vpcC": Data(vpcc)]
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
        playbackLog.notice("BORAMIN_VP9 hardware confirmed")
        return session
    }
    private func run() throws {
        var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
        let opened = remote.map { media_open_io($0.makeIO(), &info, &error, error.count) } ?? media_open(path, &info, &error, error.count)
        guard let reader = opened else { throw PlayerError(String(cString: error)) }
        defer { media_close(reader) }
        let format = try Self.makeFormat(info, configuration: PreparedMedia.configuration(reader))
        if info.vp9 == 0 {
            try runSystemVideo(reader: reader, info: info, format: format)
            return
        }
        playbackLog.notice("BORAMIN_VP9 format profile=\(info.profile) depth=\(info.bit_depth) level=\(info.level) \(info.width)x\(info.height)")
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
                playbackLog.notice("BORAMIN_VP9 seek \(target)s")
                activeRevision = revision
            }
            var bytes: UnsafePointer<UInt8>?, count: Int32 = 0, key: Int32 = 0
            var pts = 0.0, duration = 0.0
            let result = media_packet(reader, &bytes, &count, &pts, &duration, &key)
            if result < 0 { throw PlayerError("Read VP9 packet: FFmpeg \(result)") }
            if result == 0 {
                try Self.check(VTDecompressionSessionFinishDelayedFrames(session), "Drain VP9")
                playbackLog.notice("BORAMIN_VP9 reached EOF; decoded \(decoded), queued \(queued) hardware-decoded frames")
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
                            playbackLog.debug("BORAMIN_VP9 decoded=\(decoded) pts=\(timestamp.seconds)")
                            if CommandLine.arguments.contains("--vp9-diagnostics") {
                                playbackLog.debug("BORAMIN_VP9_DECODE elapsed=\(ProcessInfo.processInfo.systemUptime - diagnosticStarted) decoded=\(decoded) queued=\(queued) late=\(late)")
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

    /// Let Apple's renderer decode compressed samples and reorder B-frames by their timestamps.
    private func runSystemVideo(reader: OpaquePointer, info: MediaInfo, format: CMVideoFormatDescription) throws {
        let renderer = layer.sampleBufferRenderer
        var activeRevision = 0, submitted = 0
        var announced = false
        var previousClock: (time: Double, host: Double, rate: Double)?
        func observeClock() -> (time: Double, jumped: Bool) {
            let time = layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? 0
            let host = ProcessInfo.processInfo.systemUptime
            let rate = layer.controlTimebase.map { CMTimebaseGetRate($0) } ?? 0
            let previous = previousClock
            previousClock = (time, host, rate)
            let jumped = previous.map { abs(time - $0.time - (host - $0.host) * $0.rate) > 1 } ?? false
            return (time, jumped)
        }
        func checkRenderer() throws {
            if renderer.status == .failed { throw renderer.error ?? PlayerError("System video renderer failed.") }
            if !announced, renderer.status == .rendering {
                announced = true
                DispatchQueue.main.async { [weak self] in self?.firstFrame?() }
            }
        }
        playbackLog.notice("BORAMIN_VIDEO system decoder codec=\(info.codec_type) \(info.width)x\(info.height)")
        while true {
            let (revision, target) = try state()
            let clock = observeClock(), current = clock.time
            if revision == activeRevision, clock.jumped {
                seek(to: current); continue
            }
            if revision != activeRevision {
                let flushed = DispatchSemaphore(value: 0)
                renderer.flush(removingDisplayedImage: false) { flushed.signal() }
                while flushed.wait(timeout: .now() + 0.1) == .timedOut { _ = try state() }
                guard media_seek(reader, target) >= 0 else { throw PlayerError("Cannot seek in this file.") }
                activeRevision = revision
                lock.lock(); outputTime = -1; lock.unlock()
                playbackLog.notice("BORAMIN_VIDEO seek \(target)s")
            }
            try checkRenderer()
            var bytes: UnsafePointer<UInt8>?, count: Int32 = 0, key: Int32 = 0
            var pts = 0.0, duration = 0.0
            let result = media_packet(reader, &bytes, &count, &pts, &duration, &key)
            if result < 0 { throw PlayerError("Read video packet: FFmpeg \(result)") }
            if result == 0 {
                var marker: CMSampleBuffer?
                try Self.check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
                    formatDescription: format, sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &marker), "Create video end marker")
                if let marker {
                    CMSetAttachment(marker, key: kCMSampleBufferAttachmentKey_DrainAfterDecoding, value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
                    renderer.enqueue(marker)
                }
                playbackLog.notice("BORAMIN_VIDEO reached EOF; submitted \(submitted) compressed frames")
                while try state().0 == activeRevision { try checkRenderer(); Thread.sleep(forTimeInterval: 0.02) }
                continue
            }
            let dts = media_packet_dts(reader)
            // Decode order can differ from presentation order. Never discard late compressed
            // reference frames, and allow the renderer enough look-ahead for reordered frames.
            let decodeTime = dts.isFinite ? dts : pts
            while decodeTime > (layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? current) + 1 || !renderer.isReadyForMoreMediaData {
                if try state().0 != activeRevision { break }
                // Observe rate changes even while waiting for the paused queue to drain.
                // Otherwise a pause/resume could be mistaken for a seek discontinuity.
                let clock = observeClock()
                if clock.jumped { seek(to: clock.time); break }
                try checkRenderer()
                Thread.sleep(forTimeInterval: 0.003)
            }
            if try state().0 != activeRevision { continue }
            try autoreleasepool {
                guard count > 0, let bytes else { throw PlayerError("Empty compressed video packet.") }
                var block: CMBlockBuffer?
                try Self.check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                    blockLength: Int(count), blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: Int(count), flags: 0, blockBufferOut: &block), "Allocate video packet")
                guard let block else { throw PlayerError("No video packet buffer.") }
                try Self.check(CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: Int(count)), "Copy video packet")
                var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration > 0 ? duration : 1 / max(1, info.frame_rate), preferredTimescale: 60000),
                    presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 60000),
                    decodeTimeStamp: dts.isFinite ? CMTime(seconds: dts, preferredTimescale: 60000) : .invalid)
                var size = Int(count), sample: CMSampleBuffer?
                try Self.check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "Create compressed video sample")
                guard let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { throw PlayerError("No video sample attachments.") }
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(key != 0 ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
                renderer.enqueue(sample)
                submitted += 1
                lock.lock()
                outputTime = max(outputTime, pts)
                if self.revision == activeRevision && pts + timing.duration.seconds >= seekTime { seekPending = false }
                lock.unlock()
                if submitted % 300 == 0 { playbackLog.debug("BORAMIN_VIDEO submitted=\(submitted) pts=\(pts) dts=\(dts)") }
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
    private var diagnosticsObservers: [NSObjectProtocol] = []
    #if canImport(SwiftAssRenderer)
    private var subtitleHost: UIHostingController<PlaybackSubtitleOverlay>?
    private var tracksHost: UIHostingController<PlaybackMenuButtons>?
    private var tracks: PlaybackTracks?
    #endif
    #if os(tvOS)
    private var oledUserPaused = false
    private var oledPauseTask: Task<Void, Never>?
    private let oledPauseOverlay = UIView()
    private var displayManager: AVDisplayManager?
    private var tracksMenuSubscription: AnyCancellable?
    #endif
    private var startup: Task<Void, Never>?
    private var clockObserver: Any?
    private var exercise: Task<Void, Never>?
    private var audioLoader: StreamingAudioLoader?
    private var fileLoader: StreamingFileLoader?
    private var probeOutput: AVPlayerItemVideoOutput?
    private var probeBegan = 0.0
    private var playbackObservation: NSKeyValueObservation?
    private var debugPanel: UIView?
    private var debugLabel: UILabel?
    private var debugTimer: Timer?
    private let debugStats = PlaybackDebugStats()
    private var debugSampleTime = 0.0
    private var debugSampleBytes: Int64 = 0
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
        playbackLog.notice("Playback opened session=\(self.media.id.uuidString, privacy: .public) title=\(self.media.title, privacy: .private) sampleBuffer=\(self.media.usesSampleBufferVideo) codec=\(self.media.info.codec_type) size=\(self.media.info.width)x\(self.media.info.height) fps=\(self.media.info.frame_rate)")
        delegate = self
        #if os(iOS)
        // AVKit owns pinch-to-zoom for native video; each presentation starts fitted.
        // VP9's separate display layer retains its existing aspect-fit behavior.
        if !media.usesSampleBufferVideo { videoGravity = .resizeAspect }
        #endif
        let item: AVPlayerItem
        if let native = media.streaming?.aetherPlayer, let current = native.currentItem {
            item = current
        } else if media.usesSampleBufferVideo, let streaming = media.streaming {
            do {
                let loader = try streaming.makeAudioLoader(); audioLoader = loader
                item = AVPlayerItem(asset: loader.makeAsset())
            } catch { onFailure?(error.localizedDescription); return }
        } else if let streaming = media.streaming,
                  ["mp4", "m4v", "mov"].contains(media.timeline.pathExtension.lowercased()) {
            let loader = StreamingFileLoader(source: streaming.source, fileExtension: media.timeline.pathExtension.lowercased())
            fileLoader = loader
            item = AVPlayerItem(asset: loader.makeAsset())
            playbackLog.notice("Native remote-file resource loader enabled")
        } else { item = AVPlayerItem(url: media.timeline) }
        if CommandLine.arguments.contains("--probe-frames-only") && !media.usesSampleBufferVideo {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output); probeOutput = output
        }
        probeBegan = ProcessInfo.processInfo.systemUptime
        // Keep the bounded synthetic audio timeline responsive, but let AVPlayer
        // choose buffering and automatically recover stalls for native HTTP video.
        item.preferredForwardBufferDuration = media.usesSampleBufferVideo ? 3 : 0
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle; title.value = media.title as NSString
        item.externalMetadata = [title]
        player = media.streaming?.aetherPlayer ?? AVPlayer(playerItem: item)
        #if canImport(SwiftAssRenderer)
        let tracks = PlaybackTracks(media: media); self.tracks = tracks
        tracks.bind(player: player)
        installStyledSubtitleOverlay()
        #endif
        #if canImport(AetherEngine)
        observeAetherItemChanges()
        #if os(tvOS)
        if let tracks = self.tracks {
            tracksMenuSubscription = tracks.menuChanges.debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] in self?.refreshTransportMenu() }
            refreshTransportMenu()
        }
        #endif
        #endif
        if !media.usesSampleBufferVideo {
            // Native assets expose their audible/legible media-selection groups
            // directly to AVKit's built-in audio and subtitle controls.
            showsPlaybackControls = true
            player?.appliesMediaSelectionCriteriaAutomatically = true
        }
        if media.usesSampleBufferVideo && media.streaming != nil { player?.automaticallyWaitsToMinimizeStalling = false }
        diagnosticsObservers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            guard let self, self.active else { return }
            playbackLog.warning("Playback stalled session=\(self.media.id.uuidString, privacy: .public) position=\(item.currentTime().seconds) bufferEmpty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)")
        })
        diagnosticsObservers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            guard let self, self.active, let event = item.errorLog()?.events.last else { return }
            playbackLog.error("Player error log session=\(self.media.id.uuidString, privacy: .public) code=\(event.errorStatusCode) domain=\(event.errorDomain, privacy: .private) comment=\(event.errorComment ?? "none", privacy: .private)")
        })
        clockObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, !self.stopped else { return }
            self.media.streaming?.updateClock(time.seconds)
            let now = ProcessInfo.processInfo.systemUptime
            if CommandLine.arguments.contains("--vp9-diagnostics"), now - self.lastDiagnostic >= 2 {
                self.lastDiagnostic = now
                playbackLog.debug("BORAMIN_VP9_DIAG host=\(now) clock=\(time.seconds) rate=\(self.player?.rate ?? 0) control=\(self.player?.timeControlStatus.rawValue ?? -1) video=\(self.video?.queuedTime ?? -1) renderer=\(self.video?.layer.sampleBufferRenderer.status.rawValue ?? -1) fetched=\(self.media.streaming?.source.fetchedBytes ?? 0) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) cache=\(self.media.streaming?.source.cacheDiagnostic ?? "local")")
            }
            if now - self.lastCheckpoint >= 15 {
                let metrics = self.media.streaming?.source.transferMetrics
                playbackLog.notice("Playback health session=\(self.media.id.uuidString, privacy: .public) position=\(time.seconds) state=\(self.player?.timeControlStatus.rawValue ?? -1) residentBytes=\(media_process_resident_bytes()) cacheBytes=\(metrics?.cached ?? 0) cacheCapacity=\(metrics?.capacity ?? 0) fetchedBytes=\(metrics?.fetched ?? 0) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                self.video?.logPerformance(sessionID: self.media.id)
                self.savePosition()
                self.lastCheckpoint = now
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.stopped else { return }
            #if canImport(AetherEngine)
            if self.media.streaming?.aetherPlayback != nil {
                // AetherEngine releases its video pipeline before suspension.
                // Save and dismiss while the native player still has its item,
                // rather than returning to AVKit with an empty player shell.
                self.stop()
                self.onDismiss?()
                return
            }
            #endif
            self.savePosition()
        }
        observeCompletion(item)
        if media.usesSampleBufferVideo {
            let video = HardwareVideo(path: media.source.path, remote: media.streaming?.source)
            video.failure = { [weak self] message in
                guard let self, self.active else { return }
                playbackLog.error("BORAMIN_ERROR \(message)"); self.player?.pause(); self.onFailure?(message)
            }
            self.video = video
            contentOverlayView?.layer.insertSublayer(video.layer, at: 0)
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
                    playbackLog.error("AVPlayerItem failed code=\((item.error as NSError?)?.code ?? 0) domain=\((item.error as NSError?)?.domain ?? "unknown", privacy: .public)")
                    playbackLog.error("BORAMIN_NATIVE_ERROR \(item.error?.localizedDescription ?? "Playback failed.")")
                    playbackLog.error("BORAMIN_NATIVE_ERROR_DETAILS \(String(reflecting: item.error)) log=\(String(reflecting: item.errorLog()?.events))")
                    self.onFailure?(item.error?.localizedDescription ?? "Playback failed.")
                }
                guard item.status == .readyToPlay, !self.began else { return }
                playbackLog.notice("BORAMIN_NATIVE ready to play")
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
                    if !self.media.usesSampleBufferVideo && self.media.streaming?.aetherPlayer == nil {
                        do { try await NativeAudioSelection.selectFirstSupported(in: item) }
                        catch { guard self.active, !Task.isCancelled else { return }; self.onFailure?(error.localizedDescription); return }
                    }
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
                    if CommandLine.arguments.contains("--exercise-native-tracks") {
                        self.exercise = Task { @MainActor [weak self] in await self?.exerciseNativeTracks() }
                    } else if CommandLine.arguments.contains("--probe-frames-only") {
                        self.exercise = Task { @MainActor [weak self] in
                            guard let self else { return }
                            do { try await self.probeFrame(target: self.player?.currentTime().seconds ?? 0, after: self.probeBegan, label: "open-resume") }
                            catch { print("BORAMIN_FRAME_PROBE FAILED \(error.localizedDescription)") }
                        }
                    } else if CommandLine.arguments.contains("--exercise-stream-controls") || CommandLine.arguments.contains("--exercise-mkv-controls") {
                        self.exercise = Task { @MainActor [weak self] in await self?.exerciseStreamingControls() }
                    } else if CommandLine.arguments.contains("--exercise-resume-completion") {
                        self.exercise = Task { @MainActor [weak self] in await self?.exerciseResumeCompletion() }
                    } else if CommandLine.arguments.contains("--exercise-short-video") {
                        self.exercise = Task { @MainActor [weak self] in await self?.exerciseShortVideo() }
                    }
                }
            }
        }
        failureObservation = player?.observe(\.status, options: [.new]) { [weak self] player, _ in
            if player.status == .failed {
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    playbackLog.error("AVPlayer failed code=\((player.error as NSError?)?.code ?? 0) domain=\((player.error as NSError?)?.domain ?? "unknown", privacy: .public)")
                    self.onFailure?(player.error?.localizedDescription ?? "Player failed.")
                }
            }
        }
        #if os(tvOS)
        installPausedOLEDDimming()
        #endif
        playbackObservation = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                #if os(tvOS)
                self.updatePausedOLEDStatus(self.player?.timeControlStatus)
                #endif
                if self.player?.timeControlStatus == .playing { self.startedPlayback = true }
                else if self.player?.timeControlStatus == .paused && self.startedPlayback {
                    self.savePosition()
                    NotificationCenter.default.post(name:Notification.Name("BoraMinPlaybackSync"),object:nil)
                }
                playbackLog.notice("Playback state session=\(self.media.id.uuidString, privacy: .public) state=\(self.player?.timeControlStatus.rawValue ?? -1) position=\(self.player?.currentTime().seconds ?? 0) waitingReason=\(self.player?.reasonForWaitingToPlay?.rawValue ?? "none", privacy: .public) bufferEmpty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)")
            }
        }
    }
    #if os(tvOS)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        restartPausedOLEDDimming()
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if !context.focusHeading.isEmpty { restartPausedOLEDDimming() }
    }

    private func installPausedOLEDDimming() {
        guard let overlay = contentOverlayView else { return }
        oledPauseOverlay.frame = overlay.bounds
        oledPauseOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        oledPauseOverlay.backgroundColor = .black
        oledPauseOverlay.alpha = 0
        oledPauseOverlay.isUserInteractionEnabled = false
        overlay.addSubview(oledPauseOverlay)
        diagnosticsObservers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = self.player?.currentItem, note.object as? AVPlayerItem === item else { return }
                self.restartPausedOLEDDimming()
            }
        })
        diagnosticsObservers.append(NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, note.object as? AVPlayer === player else { return }
                self.oledUserPaused = self.startedPlayback && player.rate == 0
                    && note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason == .setRateCalled
                self.restartPausedOLEDDimming()
            }
        })
    }

    private func restartPausedOLEDDimming() {
        clearPausedOLEDDimming()
        guard active, oledUserPaused, let player,
              UserDefaults.standard.bool(forKey: "oledMode") else { return }
        oledPauseTask = Task { @MainActor [weak self, weak player] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, let player, self.active, self.player === player,
                  player.timeControlStatus == .paused,
                  self.view.window?.windowScene?.activationState == .foregroundActive else { return }
            let dimming = OLEDDimming(rawValue: UserDefaults.standard.integer(forKey: OLEDDimming.key))
                ?? OLEDDimming.defaultValue
            self.oledPauseOverlay.alpha = CGFloat(dimming.opacity)
        }
    }

    private func updatePausedOLEDStatus(_ status: AVPlayer.TimeControlStatus?) {
        if status == .playing { oledUserPaused = false }
        if status == .paused {
            if oledPauseTask == nil { restartPausedOLEDDimming() }
        } else {
            clearPausedOLEDDimming()
        }
    }

    private func clearPausedOLEDDimming() {
        oledPauseTask?.cancel()
        oledPauseTask = nil
        oledPauseOverlay.alpha = 0
    }
    #endif
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        playbackLog.warning("Memory warning session=\(self.media.id.uuidString, privacy: .public) residentBytes=\(media_process_resident_bytes())")
    }
    private func restorePosition() async {
        var saved = media.positionKey.flatMap { PlaybackPositions.shared.position(for: $0, duration: media.info.duration) }
        if CommandLine.arguments.contains("--probe-frames-only"), CommandLine.arguments.contains("--test-resume-position") {
            // Isolated preferences exercise the save/load/restore flow without changing user history or iCloud.
            let domain = "BoraMin.RemuxProbe.\(UUID().uuidString)"
            if let defaults = UserDefaults(suiteName: domain) {
                let positions = PlaybackPositions(defaults: defaults)
                positions.save(75, duration: media.info.duration, for: "probe")
                saved = positions.position(for: "probe", duration: media.info.duration)
                defaults.removePersistentDomain(forName: domain)
            }
        }
        guard let saved, let player else { restoredPosition = true; return }
        // Start at the preceding keyframe so resuming never skips unwatched
        // content and doesn't require decoding a long preroll after audio starts.
        let target = media.usesSampleBufferVideo && !media.keyframes.isEmpty ? (media.keyframes.last { $0 <= saved } ?? 0) : saved
        let success = await player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        guard !Task.isCancelled, active else { return }
        if success {
            playbackLog.notice("BORAMIN_RESUME restored saved=\(saved)s target=\(target)s")
        } else {
            if let key = media.positionKey { PlaybackPositions.shared.clear(key) }
            _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        restoredPosition = true
    }
    private func savePosition() {
        guard !CommandLine.arguments.contains("--no-playback-history"),
              !completedPlayback, restoredPosition, startedPlayback, let key = media.positionKey, let player,
              player.currentItem?.status == .readyToPlay else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        PlaybackPositions.shared.save(seconds, duration: media.info.duration, for: key, subtitle: media.subtitleSelection, audio: media.audioSelection)
        playbackLog.debug("BORAMIN_RESUME saved \(seconds)s")
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
        #if canImport(AetherEngine)
        if aetherRouteNeedsSoftwarePresentation { super.viewWillDisappear(animated); return }
        #endif
        if isBeingDismissed || parent?.isBeingDismissed == true { player?.pause() }
        savePosition()
        NotificationCenter.default.post(name:Notification.Name("BoraMinPlaybackSync"),object:nil)
        super.viewWillDisappear(animated)
    }
    private func setDebugInfoVisible(_ enabled: Bool) {
        guard active else { return }
        if enabled {
            installDebugInfo()
        } else {
            debugTimer?.invalidate(); debugTimer = nil
            debugPanel?.removeFromSuperview(); debugPanel = nil; debugLabel = nil
        }
    }
    private func installDebugInfo() {
        guard debugPanel == nil, UserDefaults.standard.bool(forKey: "showDebugInfo"), let overlay = contentOverlayView else { return }
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
        let decoder = media.usesSampleBufferVideo && media.info.vp9 != 0 ? "Hardware Decoding" : "System Decoding (HW/SW unknown)"
        label.text = ([network, cache, "Video: \(resolution), \(fps)", "Decoder: \(decoder)"] + debugStats.lines(item: player?.currentItem, video: video)).joined(separator: "\n")
        debugSampleTime = now
    }
    private func observeCompletion(_ item: AVPlayerItem) {
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                playbackLog.notice("BORAMIN_NATIVE playback reached end")
                guard let self, self.active, !self.completedPlayback else { return }
                self.completedPlayback = true
                if let key = self.media.positionKey { PlaybackPositions.shared.clear(key) }
                // Dismiss the existing full-screen presentation, preserving browser navigation.
                self.onDismiss?()
            }
        }
    }
    #if os(tvOS)
    private func refreshTransportMenu() {
        guard active else { return }
        var menus: [UIMenuElement] = []
        let usesAppSubtitleMenu = tracks?.hasAppSubtitleChoices == true
        // Filter AVKit's subtitle options when BoraMin supplies its own picker.
        // Leave native options, including Auto, available for native-only media.
        allowedSubtitleOptionLanguages = usesAppSubtitleMenu ? [] : nil
        if let tracks { menus.append(contentsOf: tracks.trackMenus(includeSubtitles: usesAppSubtitleMenu)) }
        let debug = UIAction(title: "Show Debug Info", identifier: UIAction.Identifier("boramin.debug"),
                             state: UserDefaults.standard.bool(forKey: "showDebugInfo") ? .on : .off) { [weak self] _ in
            guard let self, self.active else { return }
            let enabled = !UserDefaults.standard.bool(forKey: "showDebugInfo")
            UserDefaults.standard.set(enabled, forKey: "showDebugInfo")
            self.setDebugInfoVisible(enabled)
            self.refreshTransportMenu()
        }
        menus.append(UIMenu(title: "Settings", image: UIImage(systemName: "gearshape"),
                            identifier: UIMenu.Identifier("boramin.settings"), children: [debug]))
        transportBarCustomMenuItems = menus
    }
    #endif
    #if canImport(AetherEngine)
    private func observeAetherItemChanges() {
        guard let backend = media.streaming?.aetherPlayback else { return }
        backend.onItemChanged = { [weak self, weak backend] player, item in
            guard let self, self.active, let backend else { return }
            if let token = self.clockObserver { self.player?.removeTimeObserver(token); self.clockObserver = nil }
            self.playbackObservation = nil
            #if os(tvOS)
            self.oledUserPaused = false
            self.clearPausedOLEDDimming()
            #endif
            self.player = player
            self.clockObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                guard let self, !self.stopped else { return }
                self.media.streaming?.updateClock(time.seconds)
                let now = ProcessInfo.processInfo.systemUptime
                if CommandLine.arguments.contains("--vp9-diagnostics"), now - self.lastDiagnostic >= 2 {
                    self.lastDiagnostic = now
                    playbackLog.debug("BORAMIN_VP9_DIAG host=\(now) clock=\(time.seconds) rate=\(self.player?.rate ?? 0) control=\(self.player?.timeControlStatus.rawValue ?? -1) video=\(self.video?.queuedTime ?? -1) renderer=\(self.video?.layer.sampleBufferRenderer.status.rawValue ?? -1) fetched=\(self.media.streaming?.source.fetchedBytes ?? 0) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) cache=\(self.media.streaming?.source.cacheDiagnostic ?? "local")")
                }
                if now - self.lastCheckpoint >= 15 {
                    let metrics = self.media.streaming?.source.transferMetrics
                    playbackLog.notice("Playback health session=\(self.media.id.uuidString, privacy: .public) position=\(time.seconds) state=\(self.player?.timeControlStatus.rawValue ?? -1) residentBytes=\(media_process_resident_bytes()) cacheBytes=\(metrics?.cached ?? 0) cacheCapacity=\(metrics?.capacity ?? 0) fetchedBytes=\(metrics?.fetched ?? 0) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
                    self.video?.logPerformance(sessionID: self.media.id)
                    self.savePosition()
                    self.lastCheckpoint = now
                }
            }
            self.playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    #if os(tvOS)
                    self.updatePausedOLEDStatus(player.timeControlStatus)
                    #endif
                    if player.timeControlStatus == .playing { self.startedPlayback = true }
                    if player.timeControlStatus == .paused { self.savePosition() }
                }
            }
            self.observeCompletion(item)
            self.readiness = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    if item.status == .failed { self.onFailure?(item.error?.localizedDescription ?? "Audio track switch failed.") }
                }
            }
            self.tracks?.bind(player: player)
            #if os(tvOS)
            self.refreshTransportMenu()
            #endif
        }
    }
    #endif
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
    #if canImport(SwiftAssRenderer)
    private func installStyledSubtitleOverlay() {
        guard let overlay = contentOverlayView else { return }
        if media.streaming?.externalSubtitles != nil || media.streaming?.aetherPlayback != nil {
            let host = UIHostingController(rootView: PlaybackSubtitleOverlay(media: media))
            host.view.backgroundColor = .clear; host.view.isUserInteractionEnabled = false
            addChild(host); overlay.addSubview(host.view); host.didMove(toParent: self)
            host.view.frame = overlay.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            subtitleHost = host
        }
        #if os(iOS)
        if let tracks {
            let host = UIHostingController(rootView: PlaybackMenuButtons(tracks: tracks, onDebugChanged: { [weak self] enabled in
                self?.setDebugInfoVisible(enabled)
            }))
            host.view.backgroundColor = .clear; host.view.translatesAutoresizingMaskIntoConstraints = false
            host.sizingOptions = .intrinsicContentSize
            addChild(host); overlay.addSubview(host.view); host.didMove(toParent: self)
            NSLayoutConstraint.activate([host.view.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -20), host.view.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -112)])
            tracksHost = host
        }
        #endif
    }
    #endif
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); video?.layer.frame = contentOverlayView?.bounds ?? view.bounds
        #if canImport(SwiftAssRenderer)
        if let host = subtitleHost {
            host.view.frame = contentOverlayView?.bounds ?? view.bounds
            #if os(iOS)
            host.rootView = PlaybackSubtitleOverlay(media: media, videoRect: videoBounds)
            #endif
        }
        #endif
    }
    #if os(tvOS)
    func playerViewController(_ playerViewController: AVPlayerViewController, timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
        let seconds = media.seekTime(targetTime.seconds)
        if media.usesSampleBufferVideo { video?.seek(to: seconds) }
        playbackLog.notice("BORAMIN_NATIVE seek requested=\(targetTime.seconds) keyframe=\(seconds)")
        return CMTime(seconds: seconds, preferredTimescale: 60000)
    }
    #endif
    // Diagnostic only: exercise the same public media selections AVKit's built-in
    // picker uses. Never creates replacement controls or renders captions itself.
    private func exerciseNativeTracks() async {
        guard !media.usesSampleBufferVideo, let player, let item = player.currentItem else { return }
        do {
            guard let audio = try await item.asset.loadMediaSelectionGroup(for: .audible), audio.options.count >= 2,
                  let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible), subtitles.options.count >= 2 else {
                throw PlayerError("Native test fixture needs two audio and two subtitle tracks.")
            }
            print("BORAMIN_NATIVE_TRACKS groups audio=\(audio.options.count) subtitles=\(subtitles.options.count) allowsOff=\(subtitles.allowsEmptySelection)")
            for option in audio.options {
                item.select(option, in: audio)
                try await Task.sleep(for: .seconds(1))
                guard item.currentMediaSelection.selectedMediaOption(in: audio) == option else { throw PlayerError("Native audio selection failed.") }
                print("BORAMIN_NATIVE_TRACKS selected audio \(option.displayName)")
            }
            for option in subtitles.options {
                item.select(option, in: subtitles)
                try await Task.sleep(for: .seconds(1))
                guard item.currentMediaSelection.selectedMediaOption(in: subtitles) == option else { throw PlayerError("Native subtitle selection failed.") }
                print("BORAMIN_NATIVE_TRACKS selected subtitles \(option.displayName)")
            }
            item.select(nil, in: subtitles)
            guard item.currentMediaSelection.selectedMediaOption(in: subtitles) == nil else { throw PlayerError("Native subtitles Off failed.") }
            player.pause()
            let paused = player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(500))
            guard abs(player.currentTime().seconds - paused) < 0.1 else { throw PlayerError("Native pause failed.") }
            let success = await player.seek(to: CMTime(seconds: 20, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard success else { throw PlayerError("Native seek failed.") }
            item.select(audio.options[0], in: audio)
            item.select(subtitles.options[0], in: subtitles)
            player.play()
            try await Task.sleep(for: .seconds(2))
            guard player.currentTime().seconds > 21, item.status == .readyToPlay, isReadyForDisplay else { throw PlayerError("Native playback did not continue after selections and seek.") }
            print("BORAMIN_NATIVE_TRACKS PASS standard audio/subtitle selections, Off, pause and seek; native display ready")
        } catch is CancellationError { }
        catch { print("BORAMIN_NATIVE_TRACKS FAILED \(error.localizedDescription)") }
    }
    private func exerciseShortVideo() async {
        guard let player, let video, media.info.duration > 4 else { return }
        do {
            try await Task.sleep(for: .seconds(3))
            player.pause()
            try await Task.sleep(for: .milliseconds(500))
            guard let pixel = video.layer.sampleBufferRenderer.displayedPixelBuffer() else { throw PlayerError("Short test has no displayed video.") }
            print("BORAMIN_SHORT_TEST displayed \(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))")
            let target = media.info.duration / 2
            let sought = await player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard sought else { throw PlayerError("Short test seek failed.") }
            player.play()
            try await Task.sleep(for: .seconds(2))
            player.pause()
            try await Task.sleep(for: .milliseconds(500))
            guard player.currentTime().seconds > target + 1,
                  video.layer.sampleBufferRenderer.displayedPixelBuffer() != nil else { throw PlayerError("Short test stalled after seek.") }
            print("BORAMIN_SHORT_TEST PASS seek target=\(target) clock=\(player.currentTime().seconds)")
            player.play()
        } catch is CancellationError { }
        catch { print("BORAMIN_SHORT_TEST FAILED: \(error.localizedDescription)") }
    }
    // Opt-in diagnostic only: require actual native output and timestamp agreement.
    private func probeFrame(target: Double, after began: Double, label: String) async throws {
        guard let player, let stream = media.streaming else { throw PlayerError("Missing test player.") }
        for _ in 0..<400 {
            try Task.checkCancellation()
            guard active, player.currentItem?.status != .failed else { throw PlayerError("Player failed during \(label).") }
            let time = player.currentTime()
            if let output = probeOutput, time.seconds >= target - 0.15, output.hasNewPixelBuffer(forItemTime: time) {
                var display = CMTime.invalid
                if let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display),
                   display.isNumeric, abs(display.seconds - time.seconds) < 0.15, display.seconds >= target - 0.15 {
                    let metrics = stream.source.transferMetrics
                    print("BORAMIN_FRAME_PROBE FRAME label=\(label) latency=\(ProcessInfo.processInfo.systemUptime - began) host=\(ProcessInfo.processInfo.systemUptime) clock=\(time.seconds) pts=\(display.seconds) size=\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel)) fetched=\(metrics.fetched) cache=\(metrics.cached) resident=\(media_process_resident_bytes()) display=\(isReadyForDisplay)")
                    NotificationCenter.default.post(name: Notification.Name("BoraMinProbeFrame"), object: media.id)
                    return
                }
            } else if let video, time.seconds >= target - 0.15, video.queuedTime >= target {
                player.pause()
                if let pixel = video.layer.sampleBufferRenderer.displayedPixelBuffer() {
                    print("BORAMIN_FRAME_PROBE FRAME label=\(label) latencyUpperBound=\(ProcessInfo.processInfo.systemUptime - began) clock=\(time.seconds) size=\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel)) fetched=\(stream.source.fetchedBytes) cache=\(stream.source.transferMetrics.cached) resident=\(media_process_resident_bytes()) baseline=true")
                    NotificationCenter.default.post(name: Notification.Name("BoraMinProbeFrame"), object: media.id)
                    player.play(); return
                }
                player.play()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PlayerError("No confirmed video at \(target) during \(label).")
    }
    private func exerciseStreamingControls() async {
        guard let player, let stream = media.streaming else { return }
        do {
            try await Task.sleep(for: .seconds(6))
            player.pause()
            let before = stream.source.fetchedBytes
            try await Task.sleep(for: .seconds(2))
            print("BORAMIN_STREAM pause test at \(player.currentTime().seconds)s; extra reads \(stream.source.fetchedBytes - before)")
            if CommandLine.arguments.contains("--exercise-mkv-controls"), let video {
                guard let pixel = video.layer.sampleBufferRenderer.displayedPixelBuffer() else { throw PlayerError("No displayed video frame while paused.") }
                print("BORAMIN_MKV_TEST displayed frame \(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))")
            }
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
                    if completed == true, abs(time - seconds) < 3, paused || time > seconds + 0.2,
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
                if paused, CommandLine.arguments.contains("--exercise-mkv-controls"), let video {
                    guard let pixel = video.layer.sampleBufferRenderer.displayedPixelBuffer() else { throw PlayerError("No displayed video frame after seek.") }
                    print("BORAMIN_MKV_TEST displayed frame after seek \(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))")
                }
                if paused { player.play() }
            }
            print("BORAMIN_STREAM controls test finished at \(player.currentTime().seconds)s; SMB fetched \(stream.source.fetchedBytes)/\(stream.source.size)")
            if CommandLine.arguments.contains("--exercise-mkv-controls") {
                let end = max(0, media.info.duration - 3)
                _ = await player.seek(to: CMTime(seconds: end, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                print("BORAMIN_MKV_TEST playing to end from \(end)s")
            }
        } catch is CancellationError { }
        catch { print("BORAMIN_STREAM TEST FAILED: \(error.localizedDescription)") }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        requestLandscape()
        #endif
        #if os(tvOS)
        refreshTransportMenu()
        guard media.usesSampleBufferVideo else { return }
        let info = media.info
        if let format = media.videoFormat {
            displayManager = view.window?.avDisplayManager
            displayManager?.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(info.frame_rate), formatDescription: format)
            playbackLog.notice("Display matching session=\(self.media.id.uuidString, privacy: .public) enabled=\(self.displayManager?.isDisplayCriteriaMatchingEnabled ?? false) switchInProgress=\(self.displayManager?.isDisplayModeSwitchInProgress ?? false) requestedFPS=\(info.frame_rate)")
        }
        #endif
    }
    #if canImport(AetherEngine)
    var aetherRouteNeedsSoftwarePresentation: Bool {
        guard let backend = media.streaming?.aetherPlayback else { return false }
        return backend.engine.videoRoute == .software || backend.engine.videoRoute == .audio
    }
    #endif
    func stop(preservingAetherSession: Bool = false) {
        guard !stopped else { return }
        playbackLog.notice("Playback closing session=\(self.media.id.uuidString, privacy: .public) position=\(self.player?.currentTime().seconds ?? 0) completed=\(self.completedPlayback)")
        if !preservingAetherSession {
            savePosition()
            NotificationCenter.default.post(name:Notification.Name("BoraMinPlaybackSync"),object:nil)
        }
        stopped = true
        #if os(iOS)
        restoreMenuOrientation()
        #endif
        startup?.cancel(); startup = nil
        #if canImport(SwiftAssRenderer)
        subtitleHost?.willMove(toParent: nil); subtitleHost?.view.removeFromSuperview(); subtitleHost?.removeFromParent(); subtitleHost = nil
        tracksHost?.willMove(toParent: nil); tracksHost?.view.removeFromSuperview(); tracksHost?.removeFromParent(); tracksHost = nil
        #if os(tvOS)
        tracksMenuSubscription = nil
        #endif
        tracks?.stop(); tracks = nil
        #endif
        debugPanel?.removeFromSuperview(); debugPanel = nil; debugLabel = nil
        debugTimer?.invalidate(); debugTimer = nil
        playbackObservation = nil
        exercise?.cancel(); exercise = nil
        if !preservingAetherSession { player?.pause(); player?.replaceCurrentItem(with: nil) }
        video?.stop()
        video?.layer.removeFromSuperlayer(); video = nil
        audioLoader?.stop(); audioLoader = nil
        fileLoader?.stop(); fileLoader = nil
        if let clockObserver { player?.removeTimeObserver(clockObserver); self.clockObserver = nil }
        if !preservingAetherSession { media.streaming?.stop() }
        if let jump { NotificationCenter.default.removeObserver(jump); self.jump = nil }
        if let ended { NotificationCenter.default.removeObserver(ended); self.ended = nil }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver); self.backgroundObserver = nil }
        #if os(tvOS)
        clearPausedOLEDDimming()
        displayManager?.preferredDisplayCriteria = nil
        #endif
        readiness = nil; failureObservation = nil
        for observer in diagnosticsObservers { NotificationCenter.default.removeObserver(observer) }
        diagnosticsObservers.removeAll()
        player = nil
    }
    deinit {
        debugTimer?.invalidate()
        if let jump { NotificationCenter.default.removeObserver(jump) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        for observer in diagnosticsObservers { NotificationCenter.default.removeObserver(observer) }
        video?.stop()
    }
}

struct NativePlayer: View {
    let media: PreparedMedia
    let failure: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if canImport(AetherEngine)
        if let backend = media.streaming?.aetherPlayback {
            AetherPlaybackPresentation(media: media, backend: backend, close: { dismiss() }, failure: failure)
        } else {
            NativeAVPlayer(media: media, failure: failure)
        }
        #else
        NativeAVPlayer(media: media, failure: failure)
        #endif
    }
}

struct NativeAVPlayer: UIViewControllerRepresentable {
    let media: PreparedMedia
    let failure: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> NativePlayerController {
        let controller = NativePlayerController(media: media)
        controller.onFailure = failure; controller.onDismiss = { dismiss() }
        return controller
    }
    func updateUIViewController(_ controller: NativePlayerController, context: Context) { }
    static func dismantleUIViewController(_ controller: NativePlayerController, coordinator: ()) {
        #if canImport(AetherEngine)
        let route = controller.aetherRouteNeedsSoftwarePresentation
        controller.stop(preservingAetherSession: route)
        #else
        controller.stop()
        #endif
    }
}
#endif
