import Foundation
import CoreMedia

@main struct MKVCodecTests {
    static func main() throws {
        for path in CommandLine.arguments.dropFirst() {
            var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
            guard let reader = media_open(path, &info, &error, error.count) else { throw PlayerError(String(cString: error)) }
            defer { media_close(reader) }
            let config = try PreparedMedia.configuration(reader)
            let format = try HardwareVideo.makeFormat(info, configuration: config)
            precondition(CMFormatDescriptionGetMediaSubType(format) == info.codec_type)
            try PreparedMedia.validateDecoder(info, configuration: config)
            precondition(PreparedMedia.needsDemuxedPlayback(info, fileExtension: "mkv"))
            if info.vp9 == 0 { precondition(!PreparedMedia.needsDemuxedPlayback(info, fileExtension: "mp4")) }
            if info.codec_type == kCMVideoCodecType_H264 || info.codec_type == kCMVideoCodecType_HEVC {
                for n in 0..<min(config.count, 24) {
                    do { _ = try NativeVideoFormat.make(info, configuration: config.prefix(n)); preconditionFailure("Truncated configuration accepted") }
                    catch { }
                }
            }
            var bytes: UnsafePointer<UInt8>?, count: Int32 = 0, key: Int32 = 0
            var pts = 0.0, duration = 0.0, last = -Double.infinity
            var packets = 0, reordered = false
            while media_packet(reader, &bytes, &count, &pts, &duration, &key) == 1, packets < 600 {
                precondition(count > 0 && pts.isFinite)
                if pts < last { reordered = true }
                last = pts; packets += 1
            }
            precondition(packets > 0)
            if info.codec_type == kCMVideoCodecType_H264 || info.codec_type == kCMVideoCodecType_HEVC { precondition(reordered, "Fixture must exercise B-frame reordering") }
            precondition(media_seek(reader, 5) >= 0)
            precondition(media_packet(reader, &bytes, &count, &pts, &duration, &key) == 1 && key != 0 && pts <= 5.1)
            print("PASS: \((path as NSString).lastPathComponent) codec=\(info.codec_type) \(info.width)x\(info.height), configuration validation, native decoder, B-frame packet order and keyframe seek")
        }
        var marker: CMSampleBuffer?
        precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &marker) == noErr && marker != nil)
        print("PASS: empty drain marker construction")
    }
}
