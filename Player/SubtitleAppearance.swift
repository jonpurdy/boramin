import Foundation
import Combine
import SwiftUI

/// Per-device preference. Native AVKit captions retain the system's appearance settings.
@MainActor final class SubtitleAppearance: ObservableObject {
    static let shared = SubtitleAppearance()
    static let sizes = [100, 125, 150, 200]
    static let key = "subtitleSizePercent"
    @Published private(set) var percent: Int
    var fontScale: Double { Double(percent) / 100 }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Self.key)
        percent = Self.sizes.contains(saved) ? saved : 125
    }
    func select(_ percent: Int) {
        guard Self.sizes.contains(percent), self.percent != percent else { return }
        self.percent = percent
        defaults.set(percent, forKey: Self.key)
    }
}

struct SubtitleSizeSetting: View {
    @ObservedObject private var appearance = SubtitleAppearance.shared
    var body: some View {
        Picker("Subtitle Size", selection: Binding(get: { appearance.percent }, set: { appearance.select($0) })) {
            ForEach(SubtitleAppearance.sizes, id: \.self) { size in
                #if os(tvOS)
                Text(size == appearance.percent ? "✓ \(size)%" : "\(size)%").tag(size)
                #else
                Text("\(size)%").tag(size)
                #endif
            }
        }
    }
}
