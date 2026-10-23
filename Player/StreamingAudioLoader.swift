import OSLog
import AVFoundation
import Foundation

private let audioLog = Logger(subsystem: "com.example.BoraMin", category: "Audio")

/// AVFoundation owns request cancellation at a seek; no artificial HTTP disconnects.
final class StreamingAudioLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "BoraMin.audioAssetLoader")
    let url = URL(string: "boramin-audio://\(UUID().uuidString)/timeline.caf")!
    private let streaming: StreamingSession
    private let audio: StreamingAudio
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(streaming: StreamingSession, audio: StreamingAudio) {
        self.streaming = streaming; self.audio = audio
    }
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = AVFileType.caf.rawValue
            info.contentLength = audio.length
            info.isByteRangeAccessSupported = true
            // Every PCM range can be generated independently from the seekable
            // source. Ask CoreMedia for random-access rather than download-style
            // buffering of the synthetic CAF timeline.
            info.isEntireLengthAvailableOnDemand = true
        }
        guard let dataRequest = request.dataRequest else { request.finishLoading(); return true }
        let id = ObjectIdentifier(request)
        let start = dataRequest.currentOffset
        let requestedEnd = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
        guard start >= 0, start <= audio.length,
              dataRequest.requestsAllDataToEndOfResource || !requestedEnd.overflow else {
            request.finishLoading(with: PlayerError("Invalid audio sample range.")); return true
        }
        let end = dataRequest.requestsAllDataToEndOfResource ? audio.length : min(audio.length, requestedEnd.partialValue)
        let probe = end - start <= 65536 || start >= audio.length - 65536
        audioLog.debug("BORAMIN_AUDIO request \(start)..<\(end) probe=\(probe)")
        tasks[id] = Task.detached(priority: .userInitiated) { [self] in
            do {
                var offset = start
                while offset < end {
                    try Task.checkCancellation()
                    try await streaming.waitForAudio(offset: offset, requestStart: start, probe: probe)
                    let count = Int(min(64 * 1024, end - offset))
                    let data = try await audio.read(offset: offset, count: count)
                    guard !data.isEmpty else { throw PlayerError("Unexpected end of streaming audio.") }
                    try Task.checkCancellation()
                    let accepted = await respond(data, request: request)
                    guard accepted else { return }
                    offset += Int64(data.count)
                }
                finish(request, error: nil)
            } catch is CancellationError {
                // AVFoundation already cancelled this loading request at a seek/dismissal.
            } catch { finish(request, error: error) }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    private func respond(_ data: Data, request: AVAssetResourceLoadingRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard tasks[ObjectIdentifier(request)] != nil, !request.isCancelled else {
                    continuation.resume(returning: false); return
                }
                request.dataRequest?.respond(with: data)
                continuation.resume(returning: true)
            }
        }
    }
    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error?) {
        queue.async { [self] in
            guard tasks.removeValue(forKey: ObjectIdentifier(request)) != nil, !request.isCancelled else { return }
            if let error { request.finishLoading(with: error) } else { request.finishLoading() }
        }
    }
    func stop() {
        queue.async { [self] in
            for task in tasks.values { task.cancel() }; tasks.removeAll()
        }
    }
}

/// Native SMB file loading. AVFoundation owns parsing, decoding and controls;
/// the delegate returns unmodified bytes from the existing bounded SMB cache.
final class StreamingFileLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "BoraMin.fileAssetLoader")
    private let source: SMBRemoteFile
    private let contentType: String
    private let url: URL
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(source: SMBRemoteFile, fileExtension: String) {
        self.source = source
        contentType = fileExtension == "mov" ? AVFileType.mov.rawValue : AVFileType.mp4.rawValue
        url = URL(string: "boramin-file://\(UUID().uuidString)/source.\(fileExtension)")!
    }
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped else { request.finishLoading(with: CancellationError()); return true }
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = source.size
            info.isByteRangeAccessSupported = true
            // This is a complete, seekable source: any byte range can be fetched on
            // demand, rather than a progressively generated stream.
            info.isEntireLengthAvailableOnDemand = true
        }
        guard let dataRequest = request.dataRequest else { request.finishLoading(); return true }
        let start = dataRequest.currentOffset
        let requestedEnd = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
        guard start >= 0, start <= source.size,
              dataRequest.requestsAllDataToEndOfResource || !requestedEnd.overflow else {
            request.finishLoading(with: PlayerError("Invalid media byte range.")); return true
        }
        let end = dataRequest.requestsAllDataToEndOfResource ? source.size : min(source.size, requestedEnd.partialValue)
        let id = ObjectIdentifier(request)
        tasks[id] = Task.detached(priority: .userInitiated) { [self] in
            do {
                var offset = start
                while offset < end {
                    try Task.checkCancellation()
                    let data = try source.read(offset: offset, count: Int(min(256 * 1024, end - offset)))
                    guard !data.isEmpty else { throw PlayerError("Unexpected end of SMB file.") }
                    try Task.checkCancellation()
                    let accepted = await withCheckedContinuation { continuation in
                        queue.async { [self] in
                            guard tasks[id] != nil, !request.isCancelled, !stopped else { continuation.resume(returning: false); return }
                            request.dataRequest?.respond(with: data)
                            continuation.resume(returning: true)
                        }
                    }
                    guard accepted else { return }
                    offset += Int64(data.count)
                }
                finish(request, error: nil)
            } catch is CancellationError {
                // The request has already been cancelled by AVFoundation or teardown.
            } catch { finish(request, error: error) }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error?) {
        queue.async { [self] in
            guard tasks.removeValue(forKey: ObjectIdentifier(request)) != nil, !request.isCancelled else { return }
            if let error { request.finishLoading(with: error) } else { request.finishLoading() }
        }
    }
    func stop() {
        queue.async { [self] in
            stopped = true
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        }
    }
}
