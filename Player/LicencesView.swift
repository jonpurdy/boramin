import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Read the notices shipped with this app; repeated identical licence texts appear once.
private enum LicenceNotices {
    static func text(bundle: Bundle = .main) -> String {
        guard let directory = bundle.resourceURL?.appendingPathComponent("Licences", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return "The licence notices could not be loaded."
        }
        var groups: [(names: [String], text: String)] = []
        for file in files.filter({ $0.pathExtension == "txt" && $0.lastPathComponent != "ACKNOWLEDGEMENTS.txt" })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-LICENSE", with: "")
                .replacingOccurrences(of: "-COPYING", with: "")
                .replacingOccurrences(of: "-FTL", with: "")
            if let index = groups.firstIndex(where: { $0.text == text }) {
                groups[index].names.append(name)
            } else {
                groups.append(([name], text))
            }
        }
        let intro = (try? String(contentsOf: directory.appendingPathComponent("ACKNOWLEDGEMENTS.txt"), encoding: .utf8))
            ?? "BoraMin uses third-party open-source libraries. Their copyright notices and licences follow."
        return ([intro] + groups.map { $0.names.joined(separator: ", ") + "\n\n" + $0.text })
            .joined(separator: "\n\n────────────────────────\n\n")
    }
}

struct LicencesView: View {
    private let text = LicenceNotices.text()

    var body: some View {
        LicenceTextView(text: text)
            .navigationTitle("Licences")
    }
}

#if os(macOS)
private struct LicenceTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 20, height: 20)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) { }
}
#else
private struct LicenceTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        #if os(iOS)
        view.isEditable = false
        #endif
        view.isSelectable = true
        #if os(tvOS)
        // The Siri Remote sends indirect touches; UIKit's default pan filter
        // does not accept them for this text view.
        view.isUserInteractionEnabled = true
        view.isScrollEnabled = true
        view.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        #endif
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) { }
}
#endif
