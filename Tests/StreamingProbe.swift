import Foundation
import AVFoundation
import AMSMB2
import Darwin

@main struct StreamingProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let client = SMB2Manager(url: URL(string: "smb://127.0.0.1:16445")!, credential: URLCredential(user: "guest", password: "", persistence: .none))!
        client.timeout = 10
        try await client.connectShare(name: "TESTMEDIA")
        let local = URL(fileURLWithPath: CommandLine.arguments[1])
        let size = Int64(try local.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        let media = try await PreparedMedia.stream(client: client, path: "Nested/full.mkv", size: size, title: "Streaming test", directory: FileManager.default.temporaryDirectory, cancellation: CancellationFlag())
        let transport = media.streaming!
        defer { transport.stop() }
        precondition(media.keyframes.count > 2, "Full MKV keyframe index not available")
        for requested in [0.0, 20.0, 60.0, 90.0, 10000.0] {
            let nearest = media.seekTime(requested)
            precondition(media.keyframes.contains(nearest))
            precondition(media.keyframes.allSatisfy { abs($0 - requested) >= abs(nearest - requested) - 0.000001 })
        }
        print("PASS: nearest-keyframe mapping uses the original MKV index, including start/end clamping")
        // A native seek may request target audio before changing the playback clock
        // or calling any navigation delegate. It must preroll without beginSeek().
        let seekOffset: Int64 = 68 + 90 * 192_000
        let gate = Task { try await transport.waitForAudio(offset: seekOffset, requestStart: seekOffset, probe: false) }
        let timeout = Task { try await Task.sleep(for: .seconds(2)); gate.cancel() }
        try await gate.value
        timeout.cancel()
        // Progressive loading must still stop at the end of that preroll window.
        let bounded = Task { try await transport.waitForAudio(offset: seekOffset + 5 * 192_000, requestStart: seekOffset, probe: false) }
        try await Task.sleep(for: .milliseconds(100))
        bounded.cancel()
        do { try await bounded.value; preconditionFailure("Audio preroll was unbounded") }
        catch is CancellationError { }
        print("PASS: seek preroll needs no advance clock/delegate; read-ahead remains bounded")
        precondition(transport.source.fetchedBytes < size / 8, "startup reads too large")
        func request(_ url: URL, range: String? = nil, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url); request.httpMethod = method
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        for (range, start, count) in [("bytes=0-31", Int64(0), 32), ("bytes=-65536", size - 65536, 65536), ("bytes=10000000-10000409", Int64(10000000), 410)] {
            let (data, response) = try await request(transport.sourceURL, range: range)
            try handle.seek(toOffset: UInt64(start)); let expected = try handle.read(upToCount: count)!
            precondition(response.statusCode == 206 && data == expected)
        }
        let (empty, head) = try await request(transport.sourceURL, method: "HEAD")
        precondition(empty.isEmpty && head.value(forHTTPHeaderField: "Content-Length") == String(size))
        let (_, invalid) = try await request(transport.sourceURL, range: "bytes=999999999999999-")
        precondition(invalid.statusCode == 416)
        let (_, unauthorized) = try await request(transport.sourceURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wrong/source.mkv"))
        precondition(unauthorized.statusCode == 404)
        print("PASS: SMB HTTP head/middle/suffix ranges, HEAD, 416 and unrecognized token", terminator: "\n")
        let (audio, response) = try await request(transport.audioURL, range: "bytes=0-16451")
        precondition(response.statusCode == 206 && audio.prefix(4) == Data("caff".utf8) && audio.count == 16452)
        transport.beginSeek(90)
        let (later, laterResponse) = try await request(transport.audioURL, range: "bytes=17280068-17296451") // 90 seconds
        precondition(laterResponse.statusCode == 206 && later.count == 16384 && later.contains(where: { $0 != 0 }))
        transport.beginSeek(0)
        let (again, _) = try await request(transport.audioURL, range: "bytes=68-16451")
        precondition(again == audio.dropFirst(68), "audio start differs after seeking back")
        print("Audio HTTP ranges verified; checking AVFoundation asset")
        let audioLoader = try transport.makeAudioLoader()
        defer { audioLoader.stop() }
        let asset = audioLoader.makeAsset()
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        precondition(playable && abs(duration - media.info.duration) < 0.01, "native remote CAF not playable or incorrect duration")
        print("PASS: on-demand PCM at start/90s/back, native resource-loader CAF playable, duration \(duration)s; SMB fetched \(transport.source.fetchedBytes)/\(size) bytes")
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.automaticallyWaitsToMinimizeStalling = false
        let clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { transport.updateClock($0.seconds) }
        for (seconds, paused) in [(90.0, false), (20.0, false), (60.0, true)] {
            player.pause()
            var completed: Bool?
            // Deliberately do not call beginSeek(): real native seeks must stand alone.
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { success in
                DispatchQueue.main.async { completed = success }
            }
            if !paused { player.play() }
            for _ in 0..<300 {
                if completed != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            precondition(completed == true && abs(player.currentTime().seconds - seconds) < 3, "Native seek did not complete")
            let start = player.currentTime().seconds
            try await Task.sleep(for: .seconds(2))
            let advanced = player.currentTime().seconds - start
            precondition(paused ? abs(advanced) < 0.1 : advanced > 1, "Playback stalled after native seek")
            print("PASS: native seek \(seconds)s paused=\(paused); clock=\(player.currentTime().seconds)")
        }
        player.pause(); player.removeTimeObserver(clock); player.replaceCurrentItem(with: nil)
        precondition(transport.source.fetchedBytes < size / 3)
        let attributes = try await client.attributesOfItem(atPath: "Nested/native.mp4")
        let nativeSize = (attributes[.fileSizeKey] as! NSNumber).int64Value
        let native = try await PreparedMedia.stream(client: client, path: "Nested/native.mp4", size: nativeSize, title: "Native MP4", directory: FileManager.default.temporaryDirectory, cancellation: CancellationFlag())
        precondition(!native.vp9)
        let nativeAsset = AVURLAsset(url: native.timeline)
        let nativePlayable = try await nativeAsset.load(.isPlayable)
        let nativeDuration = try await nativeAsset.load(.duration).seconds
        precondition(nativePlayable && nativeDuration > 1.9 && nativeDuration < 2.1)
        native.streaming?.stop()
        print("PASS: native H.264/AAC MP4 streams through SMB HTTP ranges")
        transport.stop()
        do { _ = try transport.source.read(offset: 0, count: 1); preconditionFailure("Cancelled stream still readable") }
        catch is CancellationError { }
        print("PASS: streaming cancellation")
    }
}
