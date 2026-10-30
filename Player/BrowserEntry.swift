import Foundation

struct BrowserEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let directory: Bool
    let size: Int64
    var modified: Double = 0
    var duration: Double? = nil
    var progress: PlaybackProgress? = nil
    var playbackRoute: PlaybackRoute? = nil
    var displayName: String { progress.map { "\($0.prefix) \(name)" } ?? name }
    var durationText: String? {
        guard let value = duration ?? progress?.duration, value.isFinite, value > 0, value < Double(Int.max) else { return nil }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var sizeAndDuration: String {
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return durationText.map { "\($0) · \(sizeText)" } ?? sizeText
    }
    var playbackDetails: String { playbackRoute.map { "\($0.rawValue) · \(sizeAndDuration)" } ?? sizeAndDuration }
    var playable: Bool { ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "wmv", "asf", "flv", "ogv", "ogg", "rm", "rmvb", "3gp", "3g2"].contains((name as NSString).pathExtension.lowercased()) }
}

