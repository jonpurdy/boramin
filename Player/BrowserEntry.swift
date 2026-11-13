import Foundation

enum ExternalSubtitleFiles {
    struct Match {
        let ext: String
        let languageTag: String?

        func menuName(locale: Locale = .current) -> String {
            let format = "\(ext.uppercased()) — External"
            guard let languageTag else { return format }
            return "\(locale.localizedString(forIdentifier: languageTag) ?? languageTag) — \(format)"
        }
    }

    private static let languages = Set(Locale.LanguageCode.isoLanguageCodes.flatMap { code in
        [code.identifier, code.identifier(.alpha2), code.identifier(.alpha3)].compactMap { $0?.lowercased() }
    })
    private static let regions = Set(Locale.Region.isoRegions.map { $0.identifier.uppercased() })
    private static let validationLocale = Locale(identifier: "en_US_POSIX")

    static func matches(videoName: String, subtitleName: String) -> Bool {
        match(videoName: videoName, subtitleName: subtitleName) != nil
    }

    static func match(videoName: String, subtitleName: String) -> Match? {
        let ext = (subtitleName as NSString).pathExtension.lowercased()
        guard ["srt", "vtt", "ass", "ssa"].contains(ext) else { return nil }
        let videoStem = (videoName as NSString).deletingPathExtension
        let subtitleStem = (subtitleName as NSString).deletingPathExtension
        if subtitleStem == videoStem { return Match(ext: ext, languageTag: nil) }
        let prefix = videoStem + "."
        guard subtitleStem.hasPrefix(prefix) else { return nil }
        let suffix = String(subtitleStem.dropFirst(prefix.count))
        // Narrow BCP 47 subset: known language, optional script, optional region.
        // No variants, private-use tags, dot qualifiers or partial regex matches.
        let pattern = "[A-Za-z]{2,3}(?:-[A-Za-z]{4})?(?:-(?:[A-Za-z]{2}|[0-9]{3}))?"
        guard suffix.range(of: pattern, options: .regularExpression) == suffix.startIndex..<suffix.endIndex else { return nil }
        let parts = suffix.split(separator: "-").map(String.init)
        let language = parts[0].lowercased()
        guard languages.contains(language) else { return nil }
        var normalized = [Locale.LanguageCode(language).identifier(.alpha2) ?? language]
        for part in parts.dropFirst() {
            if part.count == 4 {
                let script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
                guard script != Locale.Script.unknown.identifier,
                      validationLocale.localizedString(forScriptCode: script) != nil else { return nil }
                normalized.append(script)
            } else {
                let region = part.uppercased()
                // isoRegions omits some valid numeric macroregions (e.g. 419).
                guard regions.contains(region) ||
                        (region.count == 3 && validationLocale.localizedString(forRegionCode: region) != nil) else { return nil }
                normalized.append(region)
            }
        }
        return Match(ext: ext, languageTag: normalized.joined(separator: "-"))
    }
}

struct BrowserEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let directory: Bool
    let size: Int64
    var modified: Double = 0
    var created: Date? = nil
    var sortDate: Date? {
        created ?? (modified.isFinite && modified != 0 ? Date(timeIntervalSince1970: modified) : nil)
    }
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
    func playbackDetails(alwaysUseAether: Bool) -> String {
        guard let playbackRoute else { return sizeAndDuration }
        let route = alwaysUseAether && playbackRoute == .avPlayer ? .aether : playbackRoute
        return "\(route.rawValue) · \(sizeAndDuration)"
    }
    var playable: Bool { ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "wmv", "asf", "flv", "ogv", "ogg", "rm", "rmvb", "3gp", "3g2"].contains((name as NSString).pathExtension.lowercased()) }
}


enum FolderSortOrder: String, CaseIterable {
    static let key = "folderSortOrder"

    case filenameAscending = "Filename A-Z"
    case filenameDescending = "Filename Z-A"
    case dateAscending = "Date (oldest)"
    case dateDescending = "Date (newest)"

    func precedes(_ lhs: BrowserEntry, _ rhs: BrowserEntry) -> Bool {
        if self == .dateAscending || self == .dateDescending {
            switch (lhs.sortDate, rhs.sortDate) {
            case let (left?, right?) where left != right:
                return self == .dateAscending ? left < right : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder == .orderedSame { return lhs.path < rhs.path }
        return nameOrder == (self == .filenameDescending ? .orderedDescending : .orderedAscending)
    }
}
