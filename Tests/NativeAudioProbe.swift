// Isolated Apple TV diagnostic; never compiled into BoraMin's app targets.
import SwiftUI
import AVKit
import AudioToolbox

@MainActor final class NativeAudioProbe: ObservableObject {
    let player = AVPlayer()
    @Published var status = "Native AAC compatibility test"
    private var ran = false
    func run() async {
        guard !ran else { return }; ran = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("NATIVE_AUDIO SESSION_ERROR \(error)") }
        print("NATIVE_AUDIO os=\(UIDevice.current.systemVersion) device=\(UIDevice.current.model)")
        for name in ["movie-original.mp4", "audio-original.m4a", "audio-standard.m4a", "audio-stereo.m4a", "movie-stereo.mp4"] {
            status = name
            guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
            let asset = AVURLAsset(url: url)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let playable = try await asset.load(.isPlayable)
                print("NATIVE_AUDIO ASSET \(name) audioTracks=\(tracks.count) playable=\(playable)")
                guard let track = tracks.first else {
                    print("NATIVE_AUDIO NO_AUDIO_TRACK \(name)")
                    throw NSError(domain: "NativeAudioProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVFoundation exposed no audio track"])
                }
                let formats = try await track.load(.formatDescriptions)
                for format in formats {
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                        print("NATIVE_AUDIO FORMAT \(name) channels=\(asbd.pointee.mChannelsPerFrame) rate=\(asbd.pointee.mSampleRate) codec=\(asbd.pointee.mFormatID)")
                    }
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false])
                reader.add(output)
                let began = reader.startReading()
                var buffers = 0, bytes = 0, nonzero = 0
                while began, buffers < 120, let sample = output.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let size = CMBlockBufferGetDataLength(block)
                    var data = Data(count: size)
                    let result = data.withUnsafeMutableBytes { raw in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: raw.baseAddress!)
                    }
                    guard result == noErr else { break }
                    bytes += size; nonzero += data.filter { $0 != 0 }.count; buffers += 1
                }
                print("NATIVE_AUDIO DECODE \(name) started=\(began) buffers=\(buffers) PCMbytes=\(bytes) nonzeroBytes=\(nonzero) status=\(reader.status.rawValue) error=\(String(reflecting: reader.error))")
                reader.cancelReading()
            } catch { print("NATIVE_AUDIO DECODE_ERROR \(name) \(String(reflecting: error))") }
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            player.play()
            try? await Task.sleep(for: .seconds(4))
            print("NATIVE_AUDIO PLAYER \(name) status=\(item.status.rawValue) clock=\(player.currentTime().seconds) muted=\(player.isMuted) volume=\(player.volume) error=\(String(reflecting: item.error)) log=\(String(reflecting: item.errorLog()?.events))")
            player.pause(); player.replaceCurrentItem(with: nil)
        }
        status = "Native AAC test complete"
        print("NATIVE_AUDIO COMPLETE")
    }
}
struct NativeAudioPlayer: UIViewControllerRepresentable {
    let probe: NativeAudioProbe
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = probe.player; return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { }
}
@main struct NativeAudioProbeApp: App {
    @StateObject private var probe = NativeAudioProbe()
    var body: some Scene {
        WindowGroup {
            NativeAudioPlayer(probe: probe).overlay(alignment: .topLeading) {
                Text(probe.status).padding().background(.black.opacity(0.7)).foregroundStyle(.white)
            }.task { await probe.run() }
        }
    }
}
