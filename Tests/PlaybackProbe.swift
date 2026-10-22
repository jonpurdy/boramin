import AVFoundation
import VideoToolbox

@main struct PlaybackProbe {
    static func main() async throws {
        var info = MediaInfo(), error = [CChar](repeating: 0, count: 512)
        guard let reader = media_open(CommandLine.arguments[1], &info, &error, error.count) else { throw PlayerError(String(cString: error)) }
        defer { media_close(reader) }
        let format = try HardwareVideo.makeFormat(info)
        let session = try HardwareVideo.makeSession(format)
        defer { VTDecompressionSessionInvalidate(session) }
        var bytes: UnsafePointer<UInt8>?, count: Int32 = 0, key: Int32 = 0, pts = 0.0, duration = 0.0
        var images = 0
        var packets = 0
        while media_packet(reader, &bytes, &count, &pts, &duration, &key) == 1 {
            packets += 1
            var block: CMBlockBuffer?
            try HardwareVideo.check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: Int(count), blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: Int(count), flags: 0, blockBufferOut: &block), "Allocate")
            try HardwareVideo.check(CMBlockBufferReplaceDataBytes(with: bytes!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: Int(count)), "Copy")
            var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 60000), presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 60000), decodeTimeStamp: .invalid)
            var size = Int(count), sample: CMSampleBuffer?
            try HardwareVideo.check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "Sample")
            var failure: OSStatus = 0
            try HardwareVideo.check(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                failure = status
                if image != nil { images += 1 }
            }, "Submit")
            try HardwareVideo.check(failure, "Decode")
        }
        let expected = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 600
        precondition(images == expected)
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        let playable = try await asset.load(.isPlayable)
        let length = try await asset.load(.duration).seconds
        precondition(playable && length > 1.9 && length < 2.1)
        print("PASS: \(images) VP9 frames from \(packets) packets decoded with confirmed hardware; profile=\(info.profile), depth=\(info.bit_depth), level=\(info.level); native CAF asset playable (\(length)s)")
    }
}
