// Isolated diagnostic app only; never part of BoraMin's production targets.
import SwiftUI
import AVKit
import VideoToolbox
import Network


// Diagnostic loopback transport only. Reads fixture ranges; never included in production.
final class ProbeHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NativeVP9Probe.HTTP")
    private var listener: NWListener?
    private let root: URL
    init(root: URL) { self.root = root }
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self else { connection.cancel(); return }
            var request = data
            if let bytes { request.append(bytes) }
            guard request.count <= 16384 else { connection.cancel(); return }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, text: text)
            } else if !done && error == nil { self.receive(connection, data: request) }
            else { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, text: String) {
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        guard !path.contains(".."), let decoded = path.removingPercentEncoding else { connection.cancel(); return }
        let file = root.appendingPathComponent(decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard let handle = try? FileHandle(forReadingFrom: file),
              let size = try? handle.seekToEnd(), size > 0 else {
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() }); return
        }
        defer { try? handle.close() }
        var start: UInt64 = 0, end = size - 1
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
        if let range, let value = range.components(separatedBy: "bytes=").last {
            let numbers = value.split(separator: "-", omittingEmptySubsequences: false)
            if numbers.count == 2 {
                if let first = UInt64(numbers[0]) { start = first }
                if let last = UInt64(numbers[1]) { end = min(end, last) }
            }
        }
        guard start <= end, start < size, end - start < 64 * 1024 * 1024 else { connection.cancel(); return }
        try? handle.seek(toOffset: start)
        let body = parts[0] == "HEAD" ? Data() : (try? handle.read(upToCount: Int(end - start + 1))) ?? Data()
        let type = file.pathExtension == "m3u8" ? "application/vnd.apple.mpegurl" : "video/mp4"
        let extra = range == nil ? "" : "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        let header = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: \(type)\r\nContent-Length: \(end - start + 1)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        print("NATIVE_HTTP \(path) range=\(start)-\(end) sent=\(body.count)")
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    deinit { listener?.cancel() }
}

@MainActor final class NativeVP9Probe: ObservableObject {
    let player = AVPlayer()
    @Published var status = "Starting native VP9 probe"
    private var ran = false
    private var server: ProbeHTTPServer?
    weak var controller: AVPlayerViewController?

    func run() async {
        guard !ran else { return }; ran = true
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        print("NATIVE_PROBE device=\(UIDevice.current.model) os=\(UIDevice.current.systemVersion) hardwareHint=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))")
        let hls = CommandLine.arguments.contains("--hls-only")
        var base: URL?
        if hls {
            do {
                let server = ProbeHTTPServer(root: Bundle.main.resourceURL!)
                self.server = server
                let port = try await server.start()
                base = URL(string: "http://127.0.0.1:\(port)/")!
            } catch { print("NATIVE_PROBE HTTP_ERROR \(error)"); return }
        }
        let files = hls ? ["hls/control/master.m3u8", "hls/hevc/master.m3u8", "hls/vp9/master.m3u8", "hls/vp9/index.m3u8"] : CommandLine.arguments.contains("--long-only") ? ["vp9-long.mp4"] :
            ["control.mp4", "vp9.mkv", "vp9.webm", "vp9.mp4", "vp9-video.mp4", "vp9-fragmented.mp4"]
        for file in files {
            guard let url = base?.appendingPathComponent(file) ?? Bundle.main.url(forResource: file, withExtension: nil) else {
                print("NATIVE_PROBE MISSING \(file)"); continue
            }
            status = file
            let asset = AVURLAsset(url: url)
            let began = ProcessInfo.processInfo.systemUptime
            if !hls { do {
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var descriptions: [String] = []
                for track in tracks {
                    let decodable = try await track.load(.isDecodable)
                    let formats = try await track.load(.formatDescriptions)
                    for format in formats {
                        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                        descriptions.append("codec=\(CMFormatDescriptionGetMediaSubType(format)) size=\(dimensions.width)x\(dimensions.height) decodable=\(decodable)")
                    }
                }
                print("NATIVE_PROBE ASSET \(file) playable=\(playable) tracks=\(tracks.count) \(descriptions)")
            } catch {
                print("NATIVE_PROBE ASSET_ERROR \(file) \(String(reflecting: error))")
            }
            }
            let item = AVPlayerItem(asset: asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            player.replaceCurrentItem(with: item)
            let readyDeadline = ProcessInfo.processInfo.systemUptime + 8
            while item.status == .unknown && ProcessInfo.processInfo.systemUptime < readyDeadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            player.play()
            var samples = 0, firstSize = "none"
            var firstPixel = -1.0
            let deadline = ProcessInfo.processInfo.systemUptime + (file == "vp9-long.mp4" ? 18 : 5)
            while item.status != .failed && ProcessInfo.processInfo.systemUptime < deadline {
                let time = player.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time),
                   let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    if samples == 0 { firstPixel = ProcessInfo.processInfo.systemUptime - began }
                    samples += 1
                    firstSize = "\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))"
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("NATIVE_PROBE RESULT \(file) status=\(item.status.rawValue) clock=\(player.currentTime().seconds) firstPixel=\(firstPixel) pixelSamples=\(samples) size=\(firstSize) displayReady=\(controller?.isReadyForDisplay ?? false) error=\(String(reflecting: item.error)) errorLog=\(String(reflecting: item.errorLog()?.events))")
            if file == "vp9-long.mp4", item.status == .readyToPlay {
                player.pause()
                let paused = player.currentTime().seconds
                try? await Task.sleep(for: .milliseconds(500))
                let pauseDelta = player.currentTime().seconds - paused
                let sought = await player.seek(to: CMTime(seconds: 12, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                var seekSamples = 0
                for _ in 0..<30 {
                    let time = player.currentTime()
                    if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { seekSamples += 1 }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                print("NATIVE_PROBE SEEK \(file) completed=\(sought) pauseDelta=\(pauseDelta) clock=\(player.currentTime().seconds) pixelSamples=\(seekSamples) displayReady=\(controller?.isReadyForDisplay ?? false)")
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        status = "Native VP9 probe complete"
        print("NATIVE_PROBE COMPLETE")
    }
}

struct ProbePlayer: UIViewControllerRepresentable {
    let probe: NativeVP9Probe
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = probe.player
        probe.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { }
}

@main struct NativeVP9ProbeApp: App {
    @StateObject private var probe = NativeVP9Probe()
    var body: some Scene {
        WindowGroup {
            ProbePlayer(probe: probe)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) { Text(probe.status).padding().background(.black.opacity(0.7)).foregroundStyle(.white) }
                .task { await probe.run() }
        }
    }
}
