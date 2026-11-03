#if os(tvOS)
import Foundation
import TVServices
import OSLog

extension Notification.Name {
    static let topShelfOpenItem = Notification.Name("BoraMin.topShelfOpenItem")
}

@MainActor enum TopShelfPublisher {
    private static let logger = Logger(subsystem: "com.example.BoraMin", category: "TopShelf")

    static func refresh(force: Bool = false) {
        guard let url = TopShelfSnapshot.url else {
            logger.error("Shared Top Shelf container is unavailable")
            return
        }
        let entries = PlaybackPositions.shared.watching().map {
            TopShelfEntry(id: $0.id, title: $0.file?.name ?? "Saved video · \($0.id.prefix(6))")
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        if (try? Data(contentsOf: url)) == data {
            if force { TVTopShelfContentProvider.topShelfContentDidChange() }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            logger.info("Published Top Shelf snapshot with \(entries.count) items")
            TVTopShelfContentProvider.topShelfContentDidChange()
        } catch {
            let error = error as NSError
            logger.error("Top Shelf snapshot write failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
        }
    }
}
#endif
