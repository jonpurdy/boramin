import Foundation
import Combine
import SwiftUI

/// Per-device preference. Native AVKit captions retain the system's appearance settings.
@MainActor final class SubtitleAppearance: ObservableObject {
    static let shared = SubtitleAppearance()
    static let sizes = [100, 125, 150, 200]
    static let key = "subtitleSizePercent"
    private static let scaleAllTextKey = "subtitleScaleAllText"
    struct Scaling: Equatable {
        var percent: Int
        var scaleAllText: Bool
        var factor: Double { Double(percent) / 100 }
    }
    @Published private(set) var scaling: Scaling
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Self.key)
        scaling = Scaling(
            percent: Self.sizes.contains(saved) ? saved : 125,
            scaleAllText: defaults.object(forKey: Self.scaleAllTextKey) as? Bool ?? true
        )
    }
    func select(_ percent: Int) {
        guard Self.sizes.contains(percent), scaling.percent != percent else { return }
        scaling.percent = percent
        defaults.set(percent, forKey: Self.key)
    }
    func setScaleAllText(_ enabled: Bool) {
        guard scaling.scaleAllText != enabled else { return }
        scaling.scaleAllText = enabled
        defaults.set(enabled, forKey: Self.scaleAllTextKey)
    }
}

struct SubtitleSizeSetting: View {
    @ObservedObject private var appearance = SubtitleAppearance.shared
    var body: some View {
        Picker("Subtitle Size", selection: Binding(get: { appearance.scaling.percent }, set: { appearance.select($0) })) {
            ForEach(SubtitleAppearance.sizes, id: \.self) { size in
                #if os(tvOS)
                Text(size == appearance.scaling.percent ? "✓ \(size)%" : "\(size)%").tag(size)
                #else
                Text("\(size)%").tag(size)
                #endif
            }
        }
        Toggle("Subtitles: scale all text", isOn: Binding(
            get: { appearance.scaling.scaleAllText }, set: { appearance.setScaleAllText($0) }
        ))
        .toggleStyle(.switch)
        Text("Include positioned ASS text and drawings.")
            .font(.body).foregroundStyle(.secondary)
    }
}

struct SettingsVersionFooter: View {
    var body: some View {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            Text(verbatim: "v\(version) (\(build))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
