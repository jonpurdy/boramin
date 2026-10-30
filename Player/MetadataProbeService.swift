import Foundation
import AMSMB2
#if canImport(AetherEngine)
import AetherEngine
#endif

private final class MetadataConnectionResult: @unchecked Sendable {
    var error: Error?
}

/// Serial, bounded metadata reads. The browser owns cache updates and cancellation lifetimes.
enum MetadataProbeService {
    private static let queue = DispatchQueue(label: "BoraMin.metadataProbe", qos: .utility)

    static func inspect(session: RemoteSession, path: String, size: Int64, fileExtension: String,
                        shareToConnect: String? = nil, cancellation flag: CancellationFlag) async -> (Double?, PlaybackRoute?) {
        if let client = session.smb {
            // Preserve SMB's serialized connection setup and flag-based cancellation.
            return await inspectSMB(client: client, path: path, size: size, fileExtension: fileExtension,
                shareToConnect: shareToConnect, cancellation: flag)
        }
        return await withTaskCancellationHandler {
            do {
                guard !flag.cancelled else { return (nil, nil) }
                let source = try await session.openFile(path: path, size: size, cancellation: flag)
                let result = await withCheckedContinuation { continuation in
                    queue.async {
                        guard !flag.cancelled else { continuation.resume(returning: (nil as Double?, nil as PlaybackRoute?)); return }
                        continuation.resume(returning: inspectMetadata(source: source, fileExtension: fileExtension))
                    }
                }
                if shareToConnect != nil { await session.disconnect() }
                return result
            } catch {
                if shareToConnect != nil { await session.disconnect() }
                return (nil, nil)
            }
        } onCancel: { flag.cancel() }
    }

    private static func inspectSMB(client: SMB2Manager, path: String, size: Int64, fileExtension: String,
                        shareToConnect: String? = nil, cancellation flag: CancellationFlag) async -> (Double?, PlaybackRoute?) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !flag.cancelled else { continuation.resume(returning: (nil, nil)); return }
                    defer {
                        if shareToConnect != nil { client.disconnectShare(gracefully: true) { _ in } }
                    }
                    if let shareToConnect {
                        // Keep temporary Watching probes off the browser's active session.
                        let completed = DispatchSemaphore(value: 0)
                        let outcome = MetadataConnectionResult()
                        client.connectShare(name: shareToConnect) { error in outcome.error = error; completed.signal() }
                        while completed.wait(timeout: .now() + 0.1) == .timedOut {
                            if flag.cancelled { continuation.resume(returning: (nil, nil)); return }
                        }
                        guard outcome.error == nil, !flag.cancelled else { continuation.resume(returning: (nil, nil)); return }
                    }
                    let source = CachedRemoteFile(client: client, path: path, size: size, cancellation: flag)
                    continuation.resume(returning: inspectMetadata(source: source, fileExtension: fileExtension))
                }
            }
        } onCancel: { flag.cancel() }
    }

    private static func inspectMetadata(source: CachedRemoteFile, fileExtension: String) -> (Double?, PlaybackRoute?) {
        var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
        if let reader = media_open_io(source.makeIO(), &info, &error, error.count) {
            media_close(reader)
            return (info.duration, PlaybackRoute.expected(fileExtension: fileExtension, vp9: info.vp9 != 0))
        }
        #if canImport(AetherEngine)
        if !source.cancellation.cancelled {
            let reader = AetherFileReader(source: source)
            defer { reader.close() }
            if let probe = try? AetherEngine.probe(source: .custom(reader, formatHint: nil)) {
                return (probe.durationSeconds, PlaybackRoute.expected(fileExtension: fileExtension, vp9: probe.videoCodecName == "vp9"))
            }
        }
        #endif
        return (nil, nil)
    }
}
