import TVServices
import UIKit

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let url = TopShelfSnapshot.url,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TopShelfEntry].self, from: data),
              !entries.isEmpty,
              let image1x = filmImageURL(scale: 1),
              let image2x = filmImageURL(scale: 2) else {
            completionHandler(nil)
            return
        }
        let items = entries.map { entry in
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.title
            item.imageShape = .square
            let artwork = entry.artwork.flatMap { TopShelfSnapshot.artworkURL($0) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            item.setImageURL(artwork ?? image1x, for: .screenScale1x)
            item.setImageURL(artwork ?? image2x, for: .screenScale2x)
            if let url = TopShelfSnapshot.actionURL(for: entry.id) {
                item.displayAction = TVTopShelfAction(url: url)
                item.playAction = TVTopShelfAction(url: url)
            }
            return item
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Watching"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }

    private func filmImageURL(scale: CGFloat) -> URL? {
        guard let directory = TopShelfSnapshot.url?.deletingLastPathComponent() else { return nil }
        // Version the filename so the system cannot reuse a cached missing image.
        let url = directory.appendingPathComponent("film-square-v2-\(Int(scale))x.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        let size = TVTopShelfSectionedContent.imageSize(for: .square)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let config = UIImage.SymbolConfiguration(pointSize: size.height * 0.45, weight: .regular)
        guard let symbol = UIImage(systemName: "film", withConfiguration: config)?
            .withTintColor(.lightGray, renderingMode: .alwaysOriginal) else { return nil }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2,
                                   y: (size.height - symbol.size.height) / 2))
        }
        guard let data = image.pngData(), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}
