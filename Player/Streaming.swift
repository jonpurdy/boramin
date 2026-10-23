import OSLog
import Foundation
import Network
import AMSMB2

private let streamingLog = Logger(subsystem: "com.example.BoraMin", category: "Streaming")

/// A seekable SMB file with a fixed-size, in-memory block cache. Never writes the movie to disk.
final class SMBRemoteFile: @unchecked Sendable {
    let size: Int64
    let cancellation: CancellationFlag
    private let client: SMB2Manager
    private let path: String
    private let lock = NSLock()
    private let metricsLock = NSLock()
    private let blockSize: Int64
    private let maxBlocks: Int
    private let diagnostics = CommandLine.arguments.contains("--vp9-diagnostics")
    private var seenBlocks: Set<Int64> = []
    private var cacheHits = 0
    private var cacheMisses = 0
    private var refetchedBytes: Int64 = 0
    private var blocks: [Int64: Data] = [:]
    private var recent: [Int64] = []
    private var fetched: Int64 = 0
    private var residentBytes: Int64 = 0
    private var testDelay = 0.0
    private var testUnavailableUntil = 0.0
    func configureTestNetwork(delay: Double = 0, unavailableFor: Double = 0) {
        guard CommandLine.arguments.contains("--exercise-remux-faults") else { return }
        metricsLock.lock(); defer { metricsLock.unlock() }
        testDelay = min(0.25, max(0, delay))
        testUnavailableUntil = ProcessInfo.processInfo.systemUptime + max(0, unavailableFor)
    }

    init(client: SMB2Manager, path: String, size: Int64, cancellation: CancellationFlag) {
        self.client = client; self.path = path; self.size = size; self.cancellation = cancellation
        // Shared default for all streaming formats on iOS and tvOS; test flags can override it.
        var cacheMiB = 128
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--test-stream-cache-mib"), args.count > index + 1,
           let value = Int(args[index + 1]), [32, 64, 128, 256].contains(value) { cacheMiB = value }
        var blockKiB = 256
        if let index = args.firstIndex(of: "--test-stream-block-kib"), args.count > index + 1,
           let value = Int(args[index + 1]), [256, 512, 1024].contains(value) { blockKiB = value }
        blockSize = Int64(blockKiB * 1024)
        maxBlocks = cacheMiB * 1024 / blockKiB
    }
    var cacheDiagnostic: String {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return "MiB=\(Int64(maxBlocks) * blockSize / 1048576),blockKiB=\(blockSize / 1024),hits=\(cacheHits),misses=\(cacheMisses),refetched=\(refetchedBytes)"
    }
    var fetchedBytes: Int64 { metricsLock.lock(); defer { metricsLock.unlock() }; return fetched }
    var transferMetrics: (fetched: Int64, cached: Int64, capacity: Int64) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return (fetched, residentBytes, Int64(maxBlocks) * blockSize)
    }

    /// Called only on worker queues. Serialize cache fills while libsmb2 runs on its own queue.
    func read(offset: Int64, count: Int) throws -> Data {
        guard !cancellation.cancelled else { throw CancellationError() }
        guard offset >= 0, count > 0 else { throw PlayerError("Invalid SMB byte range.") }
        guard offset < size else { return Data() }
        lock.lock(); defer { lock.unlock() }
        guard !cancellation.cancelled else { throw CancellationError() }
        let block = offset / blockSize
        let start = block * blockSize
        let data: Data
        if let cached = blocks[block] {
            data = cached
            if diagnostics { metricsLock.lock(); cacheHits += 1; metricsLock.unlock() }
        } else {
            metricsLock.lock(); let delay = testDelay, unavailable = testUnavailableUntil; metricsLock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if ProcessInfo.processInfo.systemUptime < unavailable { throw PlayerError("Injected temporary SMB read failure.") }
            let end = min(size, start + blockSize)
            let semaphore = DispatchSemaphore(value: 0)
            let result = SMBReadResult()
            client.contents(atPath: path, range: start..<end, progress: { [cancellation] _, _ in !cancellation.cancelled }) { value in
                result.value = value; semaphore.signal()
            }
            // The SMB client has a connection timeout; leave its callback's captured state alive
            // if cancellation lets this worker return before a pending read finishes.
            while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                if cancellation.cancelled { throw CancellationError() }
            }
            do { data = try result.value!.get() }
            catch {
                let failure = error as NSError
                streamingLog.error("SMB read failed offset=\(start) count=\(end - start) code=\(failure.code) domain=\(failure.domain, privacy: .public) details=\(failure.localizedDescription, privacy: .private)")
                throw error
            }
            guard data.count == Int(end - start) else { throw PlayerError("The SMB file changed or a network read ended early.") }
            metricsLock.lock()
            fetched += Int64(data.count)
            residentBytes += Int64(data.count)
            if diagnostics {
                cacheMisses += 1
                if !seenBlocks.insert(block).inserted { refetchedBytes += Int64(data.count) }
            }
            metricsLock.unlock()
            blocks[block] = data
        }
        recent.removeAll { $0 == block }; recent.append(block)
        while recent.count > maxBlocks {
            if let removed = blocks.removeValue(forKey: recent.removeFirst()) {
                metricsLock.lock(); residentBytes -= Int64(removed.count); metricsLock.unlock()
            }
        }
        let local = Int(offset - start)
        return data.subdata(in: local..<min(data.count, local + count))
    }
    func makeIO() -> MediaIO {
        MediaIO(context: Unmanaged.passUnretained(self).toOpaque(), size: size, read: { context, offset, output, count in
            guard let context, let output else { return -1 }
            do {
                let data = try Unmanaged<SMBRemoteFile>.fromOpaque(context).takeUnretainedValue().read(offset: offset, count: Int(count))
                data.copyBytes(to: output, count: data.count)
                return Int32(data.count)
            } catch { return -1 }
        }, cancelled: { context in
            guard let context else { return 1 }
            return Unmanaged<SMBRemoteFile>.fromOpaque(context).takeUnretainedValue().cancellation.cancelled ? 1 : 0
        })
    }
}

private final class SMBReadResult: @unchecked Sendable {
    // Written before signalling the semaphore, read only after the waiter acquires it.
    var value: Result<Data, Error>?
}

/// Decode only requested audio samples. A private serial queue owns the FFmpeg audio context.
final class StreamingAudio: @unchecked Sendable {
    let length: Int64
    private let header: Data
    private let source: SMBRemoteFile
    private let duration: Double
    private let queue = DispatchQueue(label: "BoraMin.streamingAudio", qos: .userInitiated)
    private var reader: OpaquePointer?
    private var stopped = false

    init(source: SMBRemoteFile, duration: Double) throws {
        var bytes = [UInt8](repeating: 0, count: 68)
        let length = media_caf_header(duration, &bytes)
        guard length > 68 else { throw PlayerError("This video has no usable duration.") }
        self.source = source; self.duration = duration; self.length = length; self.header = Data(bytes)
    }
    func read(offset: Int64, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try readOnQueue(offset: offset, count: count)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func readOnQueue(offset: Int64, count: Int) throws -> Data {
        guard !stopped, !source.cancellation.cancelled else { throw CancellationError() }
        guard offset >= 0, offset < length, count > 0 else { return Data() }
        var position = offset
        let end = min(length, offset + Int64(count))
        var result = Data()
        if position < 68 {
            let headerEnd = min(68, end)
            result.append(header.subdata(in: Int(position)..<Int(headerEnd)))
            position = headerEnd
        }
        if position < end {
            if reader == nil {
                var error = [CChar](repeating: 0, count: 512)
                reader = media_pcm_open(source.makeIO(), duration, &error, error.count)
                guard reader != nil else { throw PlayerError("Open streaming audio: \(String(cString: error))") }
            }
            let first = (position - 68) / 4, skip = Int((position - 68) % 4)
            let needed = Int(end - position)
            let frames = (skip + needed + 3) / 4
            var bytes = [UInt8](repeating: 0, count: frames * 4)
            let size = media_pcm_read(reader, first, Int32(frames), &bytes)
            guard size >= skip + needed else { throw PlayerError("Read streaming audio: FFmpeg \(size)") }
            result.append(contentsOf: bytes[skip..<(skip + needed)])
        }
        return result
    }
    func stop() {
        queue.async { [self] in stopped = true; if let reader { media_pcm_close(reader); self.reader = nil } }
    }
    deinit { if let reader { media_pcm_close(reader) } }
}

struct HTTPByteRange: Equatable {
    let start: Int64
    let end: Int64 // exclusive
    static func parse(_ value: String?, length: Int64) throws -> Self {
        guard length > 0 else { throw PlayerError("Empty media.") }
        guard let value else { return Self(start: 0, end: length) }
        guard value.hasPrefix("bytes="), !value.contains(",") else { throw PlayerError("Unsupported byte range.") }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw PlayerError("Invalid byte range.") }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw PlayerError("Invalid suffix range.") }
            return Self(start: max(0, length - suffix), end: length)
        }
        guard let start = Int64(parts[0]), start >= 0, start < length else { throw PlayerError("Range outside media.") }
        if parts[1].isEmpty { return Self(start: start, end: length) }
        guard let last = Int64(parts[1]), last >= start else { throw PlayerError("Invalid range end.") }
        return Self(start: start, end: last >= length - 1 ? length : last + 1)
    }
}

/// AVPlayer consumes HTTP ranges; FFmpeg consumes the same cached SMB source through custom AVIO.
/// The listener is reachable only on this device's loopback interface, with a random per-play token.
final class StreamingSession: @unchecked Sendable {
    let source: SMBRemoteFile
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BoraMin.loopback")
    private let token = UUID().uuidString
    private let ext: String
    private var port: UInt16 = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var audioConnections: Set<ObjectIdentifier> = []
    private var ready: CheckedContinuation<Void, Error>?
    private let audioLock = NSLock()
    private var audio: StreamingAudio?
    private var playbackSeconds = 0.0
    private var experimentalRemux: ExperimentalRemux?
    private let stopLock = NSLock()
    private var stopped = false

    init(source: SMBRemoteFile, fileExtension: String) throws {
        self.source = source
        self.ext = fileExtension.lowercased().filter { $0.isASCII && $0.isLetter || $0.isNumber }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    var sourceURL: URL { URL(string: "http://127.0.0.1:\(port)/\(token)/source.\(ext)")! }
    var audioURL: URL { URL(string: "http://127.0.0.1:\(port)/\(token)/audio.caf")! }
    var experimentalRemuxURL: URL { URL(string: "http://127.0.0.1:\(port)/\(token)/remux/index.m3u8")! }
    func configureExperimentalRemux(info: MediaInfo, keyframes: [Double]) throws {
        experimentalRemux = try ExperimentalRemux(source: source, info: info, keyframes: keyframes)
    }
    func configureAudio(duration: Double) throws {
        let audio = try StreamingAudio(source: source, duration: duration)
        audioLock.lock(); self.audio = audio; audioLock.unlock()
    }
    func updateClock(_ seconds: Double) {
        guard seconds.isFinite else { return }
        audioLock.lock(); defer { audioLock.unlock() }
        playbackSeconds = max(0, seconds)
    }
    private func audioReadLimit() -> Int64 {
        audioLock.lock(); let seconds = playbackSeconds; audioLock.unlock()
        return 68 + Int64((seconds + 5) * 192_000)
    }
    func makeAudioLoader() throws -> StreamingAudioLoader {
        guard let audio = currentAudio() else { throw PlayerError("Audio timeline is unavailable.") }
        return StreamingAudioLoader(streaming: self, audio: audio)
    }
    func waitForAudio(offset: Int64, requestStart: Int64, probe: Bool) async throws {
        guard !source.cancellation.cancelled else { throw CancellationError() }
        if probe { return }
        // A new native loading request is itself permission to preroll its first
        // five seconds. Seek completion may need that data before the player clock
        // moves, and skip/remote seeks don't all call the navigation delegate.
        if offset >= requestStart && offset - requestStart < 5 * 192_000 { return }
        while !audioRangeIsCurrent(offset) {
            try await Task.sleep(for: .milliseconds(25))
            guard !source.cancellation.cancelled else { throw CancellationError() }
        }
    }
    private func audioRangeIsCurrent(_ offset: Int64) -> Bool {
        audioLock.lock(); let seconds = playbackSeconds; audioLock.unlock()
        let time = max(0, Double(offset - 68) / 192_000)
        return time <= seconds + 5 && time >= max(0, seconds - 5)
    }
    func beginSeek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        updateClock(seconds)
        queue.async { [self] in
            for id in audioConnections { tasks[id]?.cancel(); connections[id]?.cancel() }
            audioConnections.removeAll()
        }
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = self.listener.port!.rawValue
                        self.ready?.resume(); self.ready = nil
                    case .failed(let error): self.ready?.resume(throwing: error); self.ready = nil
                    case .cancelled: self.ready?.resume(throwing: CancellationError()); self.ready = nil
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            }
        }
    }
    func stop() {
        stopLock.lock()
        if stopped { stopLock.unlock(); return }
        stopped = true; stopLock.unlock()
        source.cancellation.cancel()
        experimentalRemux?.stop()
        audioLock.lock(); let audio = audio; audioLock.unlock(); audio?.stop()
        queue.async { [self] in
            listener.cancel()
            for task in tasks.values { task.cancel() }; tasks.removeAll()
            for connection in connections.values { connection.cancel() }; connections.removeAll()
            streamingLog.notice("BORAMIN_STREAM stopped; SMB fetched \(self.source.fetchedBytes) of \(self.source.size) bytes")
        }
    }
    private func accept(_ connection: NWConnection) {
        if experimentalRemux != nil && connections.count >= 4 { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.tasks[id]?.cancel(); connection.cancel() }
        }
        connection.start(queue: queue)
        tasks[id] = Task.detached(priority: .userInitiated) { [self] in
            do { try await respond(connection) }
            catch { /* Reader cancellation or a disconnected HTTP consumer ends only this request. */ }
            connection.stateUpdateHandler = nil
            connection.cancel()
            queue.async { [self] in connections.removeValue(forKey: id); tasks.removeValue(forKey: id); audioConnections.remove(id) }
        }
    }
    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: PlayerError(complete ? "HTTP connection closed." : "Empty HTTP request.")) }
            }
        }
    }
    private func send(_ data: Data, to connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func respond(_ connection: NWConnection) async throws {
        var request = Data()
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            request.append(try await receive(connection))
            guard request.count <= 16 * 1024 else { return }
        }
        guard let text = String(data: request, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD" else { return }
        let path = String(first[1])
        if path.hasPrefix("/\(token)/remux/"), let remux = experimentalRemux {
            do {
                let (data, type) = try await remux.resource(String(path.dropFirst("/\(token)/remux/".count)))
                let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                let range = try HTTPByteRange.parse(rangeHeader, length: Int64(data.count))
                var header = "HTTP/1.1 \(rangeHeader == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: \(type)\r\nContent-Length: \(range.end - range.start)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
                if rangeHeader != nil { header += "Content-Range: bytes \(range.start)-\(range.end - 1)/\(data.count)\r\n" }
                try await send(Data((header + "\r\n").utf8), to: connection)
                if first[0] == "GET" {
                    var offset = Int(range.start)
                    while offset < Int(range.end) {
                        let end = min(offset + 65536, Int(range.end))
                        try await send(data.subdata(in: offset..<end), to: connection); offset = end
                    }
                }
            } catch {
                streamingLog.error("BORAMIN_REMUX HTTP_ERROR \(error.localizedDescription)")
                try? await send(Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection)
            }
            return
        }
        let audio = currentAudio()
        let isAudio = path == "/\(token)/audio.caf"
        if isAudio { await registerAudio(connection) }
        streamingLog.debug("BORAMIN_HTTP \(first[0]) \(isAudio ? "audio" : "source")")
        guard path == sourceURL.path || (isAudio && audio != nil) else {
            try await send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
        }
        let length = isAudio ? audio!.length : source.size
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let range: HTTPByteRange
        do { range = try HTTPByteRange.parse(rangeHeader, length: length) }
        catch {
            try await send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(length)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
        }
        // CoreMedia may finish a small probe from the previous position while a seek
        // is pending. Complete those bounded requests; gate only progressive bodies.
        let probe = isAudio && (range.end - range.start <= 65536 || range.start >= length - 65536)
        let mime = isAudio ? "audio/x-caf" : (["mp4", "m4v"].contains(ext) ? "video/mp4" : ext == "mov" ? "video/quicktime" : "application/octet-stream")
        var headers = "HTTP/1.1 \(rangeHeader == nil ? "200 OK" : "206 Partial Content")\r\nAccept-Ranges: bytes\r\nContent-Type: \(mime)\r\nContent-Length: \(range.end - range.start)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if rangeHeader != nil { headers += "Content-Range: bytes \(range.start)-\(range.end - 1)/\(length)\r\n" }
        try await send(Data((headers + "\r\n").utf8), to: connection)
        streamingLog.debug("BORAMIN_HTTP \(isAudio ? "audio" : "source") range \(range.start)..<\(range.end)")
        guard first[0] == "GET" else { return }
        var offset = range.start
        while offset < range.end {
            try Task.checkCancellation()
            guard !source.cancellation.cancelled else { throw CancellationError() }
            if isAudio && !probe {
                while offset >= audioReadLimit() {
                    try await Task.sleep(for: .milliseconds(25))
                    guard !source.cancellation.cancelled else { throw CancellationError() }
                }
            }
            let count = Int(min(64 * 1024, range.end - offset))
            let data = try await (isAudio ? audio!.read(offset: offset, count: count) : readSource(offset: offset, count: count))
            guard !data.isEmpty else { throw PlayerError("Unexpected end of SMB file.") }
            try await send(data, to: connection)
            offset += Int64(data.count)
        }
    }
    private func readSource(offset: Int64, count: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [source] in try source.read(offset: offset, count: count) }.value
    }
    private func currentAudio() -> StreamingAudio? {
        audioLock.lock(); defer { audioLock.unlock() }; return audio
    }
    private func registerAudio(_ connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in audioConnections.insert(ObjectIdentifier(connection)); continuation.resume() }
        }
    }
}

/// Launch-flag-only experiment: independent VP9/AAC fragments generated on demand.
/// A serial queue owns the demuxer and a two-fragment LRU (at most 64 MiB).
final class ExperimentalRemux: @unchecked Sendable {
    private let source: SMBRemoteFile
    private let queue = DispatchQueue(label: "BoraMin.experimental-remux")
    private var reader: OpaquePointer?
    private var info: MediaInfo
    private let boundaries: [Double]
    private var initialization: Data?
    private var fragments: [Int: Data] = [:]
    private var recent: [Int] = []
    private var stopped = false
    let playlist: Data

    init(source: SMBRemoteFile, info: MediaInfo, keyframes: [Double]) throws {
        guard info.vp9 != 0, info.duration.isFinite, info.duration > 0,
              keyframes.count >= 2, keyframes.count <= 100_000,
              let first = keyframes.first, first < 0.1 else {
            throw PlayerError("Experimental remux needs an indexed VP9 file starting near zero.")
        }
        self.source = source; self.info = info
        boundaries = [0] + keyframes.dropFirst().filter { $0 < info.duration } + [info.duration]
        let durations = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }
        guard durations.allSatisfy({ $0 > 0 && $0 <= 30 }) else {
            throw PlayerError("Experimental remux requires keyframe intervals under 30 seconds.")
        }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(ceil(durations.max()!)))",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-MAP:URI=\"init.mp4\""]
        for (index, duration) in durations.enumerated() {
            lines += [String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), duration), "segment\(index).m4s"]
        }
        lines.append("#EXT-X-ENDLIST")
        playlist = Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    func resource(_ name: String) async throws -> (Data, String) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !stopped, !source.cancellation.cancelled else { throw CancellationError() }
                    if name == "index.m3u8" { continuation.resume(returning: (playlist, "application/vnd.apple.mpegurl")); return }
                    if name == "init.mp4" {
                        if initialization == nil { _ = try fragment(0) }
                        continuation.resume(returning: (initialization!, "video/mp4")); return
                    }
                    guard name.hasPrefix("segment"), name.hasSuffix(".m4s"),
                          let index = Int(name.dropFirst(7).dropLast(4)), index >= 0, index < boundaries.count - 1 else {
                        throw PlayerError("Unknown experimental remux resource.")
                    }
                    continuation.resume(returning: (try fragment(index), "video/mp4"))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func fragment(_ index: Int) throws -> Data {
        if let data = fragments[index] {
            recent.removeAll { $0 == index }; recent.append(index); return data
        }
        var error = [CChar](repeating: 0, count: 512)
        if reader == nil {
            reader = media_open_io(source.makeIO(), &info, &error, error.count)
            guard reader != nil else { throw PlayerError("Experimental remux open: \(String(cString: error))") }
        }
        let began = ProcessInfo.processInfo.systemUptime, before = source.fetchedBytes
        var bytes: UnsafeMutablePointer<UInt8>?, count: Int32 = 0, initCount: Int32 = 0
        let status = media_remux_fragment(reader, &info, boundaries[index], boundaries[index + 1], Int32(index + 1),
                                         &bytes, &count, &initCount, &error, error.count)
        defer { if let bytes { media_remux_free(bytes) } }
        guard status == 0, let bytes, initCount > 0, initCount < count, initCount < 4 * 1024 * 1024 else {
            if let reader { media_close(reader); self.reader = nil }
            throw PlayerError("Experimental remux fragment: \(String(cString: error))")
        }
        let header = Data(bytes: bytes, count: Int(initCount))
        if let initialization, initialization != header { throw PlayerError("Experimental remux initialization changed between segments.") }
        initialization = header
        let data = Data(bytes: bytes.advanced(by: Int(initCount)), count: Int(count - initCount))
        while recent.count >= 2 { fragments.removeValue(forKey: recent.removeFirst()) }
        fragments[index] = data; recent.append(index)
        streamingLog.info("BORAMIN_REMUX segment=\(index) start=\(self.boundaries[index]) end=\(self.boundaries[index + 1]) bytes=\(data.count) elapsed=\(ProcessInfo.processInfo.systemUptime - began) fetched=\(self.source.fetchedBytes - before) retained=\(self.fragments.values.reduce(0) { $0 + $1.count })")
        return data
    }
    func stop() {
        queue.async { [self] in
            stopped = true
            if let reader { media_close(reader); self.reader = nil }
            fragments.removeAll(); recent.removeAll(); initialization = nil
        }
    }
    deinit { if let reader { media_close(reader) } }
}
