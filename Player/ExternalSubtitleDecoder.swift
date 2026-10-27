import Foundation
import AetherEngine
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Uses the already bundled FFmpeg text decoders, including their SRT/VTT-to-ASS
/// conversion. No video is opened, remuxed or re-encoded.
enum ExternalSubtitleDecoder {
    static let maximumBytes = 8 * 1024 * 1024
    struct Document: Sendable {
        let header: String
        let cues: [SubtitleCue]
    }
    static func decode(_ data: Data, extension ext: String, cancellation: CancellationFlag) throws -> Document {
        guard !data.isEmpty, data.count <= maximumBytes else { throw PlayerError("The subtitle file is empty or exceeds 8 MiB.") }
        let names = ["srt": "srt", "vtt": "webvtt", "ass": "ass", "ssa": "ass"]
        guard let name = names[ext.lowercased()], let input = av_find_input_format(name) else { throw PlayerError("Unsupported subtitle format.") }
        // A private, short-lived file lets FFmpeg handle text encodings and script
        // headers. Force a text demuxer and file-only protocol; never follow URLs.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BoraMin-subtitle-\(UUID().uuidString).\(ext.lowercased())")
        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }
        var format: UnsafeMutablePointer<AVFormatContext>?
        var options: OpaquePointer?
        av_dict_set(&options, "protocol_whitelist", "file", 0)
        defer { av_dict_free(&options); avformat_close_input(&format) }
        guard !cancellation.cancelled else { throw CancellationError() }
        guard avformat_open_input(&format, url.path, input, &options) >= 0, let context = format,
              avformat_find_stream_info(context, nil) >= 0, context.pointee.nb_streams > 0,
              let stream = context.pointee.streams[0], let parameters = stream.pointee.codecpar,
              [AV_CODEC_ID_SUBRIP, AV_CODEC_ID_WEBVTT, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA].contains(parameters.pointee.codec_id),
              let codec = avcodec_find_decoder(parameters.pointee.codec_id) else { throw PlayerError("Could not read the subtitle file.") }
        var decoder = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&decoder) }
        guard let decoder, avcodec_parameters_to_context(decoder, parameters) >= 0,
              avcodec_open2(decoder, codec, nil) >= 0 else { throw PlayerError("Could not decode the subtitle file.") }
        let header: String
        if let bytes = decoder.pointee.subtitle_header, decoder.pointee.subtitle_header_size > 0 {
            header = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(decoder.pointee.subtitle_header_size)), as: UTF8.self)
        } else if let bytes = parameters.pointee.extradata, parameters.pointee.extradata_size > 0 {
            header = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(parameters.pointee.extradata_size)), as: UTF8.self)
        } else { throw PlayerError("The subtitle style header is missing.") }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw PlayerError("Could not allocate the subtitle decoder.") }
        let base = stream.pointee.time_base
        let timeBase = Double(base.num) / Double(base.den)
        var cues: [SubtitleCue] = [], textBytes = 0, packetCount = 0
        func decodePacket(_ packet: UnsafeMutablePointer<AVPacket>, anchor: Double) throws -> Bool {
            var subtitle = AVSubtitle(), got: Int32 = 0
            defer { avsubtitle_free(&subtitle) }
            guard avcodec_decode_subtitle2(decoder, &subtitle, &got, packet) >= 0 else { throw PlayerError("The subtitle file contains invalid data.") }
            guard got != 0 else { return false }
            let start = anchor + Double(subtitle.start_display_time) / 1000
            let duration = packet.pointee.duration > 0 ? Double(packet.pointee.duration) * timeBase : 5
            let end = anchor + (subtitle.end_display_time > 0 ? Double(subtitle.end_display_time) / 1000 : duration)
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return true }
            var lines: [String] = []
            if let rects = subtitle.rects {
                for index in 0..<Int(subtitle.num_rects) {
                    if let raw = rects[index]?.pointee.ass { lines.append(String(cString: raw)) }
                }
            }
            let text = lines.joined(separator: "\n")
            guard !text.isEmpty else { return true }
            textBytes += text.utf8.count
            guard cues.count < 50_000, textBytes <= maximumBytes * 2, text.utf8.count <= 65_536 else { throw PlayerError("The subtitle file exceeds the subtitle memory limit.") }
            cues.append(SubtitleCue(id: cues.count, startTime: start, endTime: end, body: .text(text)))
            return true
        }
        var lastAnchor = 0.0
        while true {
            guard !cancellation.cancelled else { throw CancellationError() }
            let status = av_read_frame(context, packet)
            if status < 0 {
                guard status == -541478725 else { throw PlayerError("The subtitle file could not be read completely.") } // AVERROR_EOF
                break
            }
            defer { av_packet_unref(packet) }
            packetCount += 1
            guard packetCount <= 100_000 else { throw PlayerError("Too many subtitle events.") }
            guard packet.pointee.stream_index == stream.pointee.index else { continue }
            lastAnchor = packet.pointee.pts == Int64.min ? 0 : Double(packet.pointee.pts) * timeBase
            _ = try decodePacket(packet, anchor: lastAnchor)
        }
        av_packet_unref(packet)
        for _ in 0..<100 {
            guard !cancellation.cancelled else { throw CancellationError() }
            if try !decodePacket(packet, anchor: lastAnchor) { break }
        }
        guard !cues.isEmpty else { throw PlayerError("No readable subtitle cues were found.") }
        return Document(header: header.replacingOccurrences(of: "\0", with: ""), cues: cues.sorted { $0.startTime < $1.startTime })
    }
}
