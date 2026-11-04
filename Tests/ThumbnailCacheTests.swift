import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct ThumbnailCacheTests {
    @MainActor static func main() throws {
        let legacy = try JSONDecoder().decode(TopShelfEntry.self, from: Data(#"{"id":"bookmark","title":"Movie"}"#.utf8))
        precondition(legacy.artwork == nil)
        let filename = String(repeating: "a", count: 64) + ".png"
        let entry = TopShelfEntry(id: "bookmark", title: "Movie", artwork: filename)
        let restoredEntry = try JSONDecoder().decode(TopShelfEntry.self, from: JSONEncoder().encode(entry))
        precondition(restoredEntry == entry)
        precondition(TopShelfSnapshot.isArtworkFilename(filename))
        for invalid in ["../cover.png", "/tmp/cover.png", "https://example.com/cover.png", "cover.png", String(repeating: "z", count: 64) + ".png"] {
            precondition(!TopShelfSnapshot.isArtworkFilename(invalid) && TopShelfSnapshot.artworkURL(invalid) == nil)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let original = NSMutableData()
        let destination = CGImageDestinationCreateWithData(original, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        try (original as Data).write(to: root.appendingPathComponent("cover.png"))
        let png = ThumbnailCache.downsample(original as Data)!
        try png.write(to: root.appendingPathComponent("illustration.png"))
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
        precondition(image.width == 320 && image.height == 180)
        precondition(image.alphaInfo != .none && image.alphaInfo != .noneSkipLast)
        precondition(ThumbnailCache.downsample(Data("invalid".utf8)) == nil)
        let directory = root.appendingPathComponent("cache")
        let key = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let cache = ThumbnailCache(directory: directory, entryLimit: 2)
        cache.save(EmbeddedArtworkResult(png: png), for: key, modified: 1)
        precondition(cache.contains(key, modified: 1) && !cache.contains(key, modified: 2))
        precondition(cache.data(for: key) == png)
        let restored = ThumbnailCache(directory: directory)
        precondition(restored.contains(key, modified: 1) && restored.data(for: key) == png)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".png"))
        precondition(!restored.contains(key))
        restored.save(EmbeddedArtworkResult(png: nil), for: key, modified: 2)
        precondition(restored.contains(key, modified: 2) && restored.data(for: key) == nil)
        precondition(ThumbnailCache(directory: directory).contains(key, modified: 2))
        let bounded = ThumbnailCache(directory: root.appendingPathComponent("bounded"), byteLimit: png.count, entryLimit: 1)
        bounded.save(EmbeddedArtworkResult(png: png), for: key, modified: 1)
        bounded.save(EmbeddedArtworkResult(png: png), for: other, modified: 1)
        precondition(!bounded.contains(key) && bounded.contains(other))
        bounded.invalidate(other)
        precondition(!ThumbnailCache(directory: root.appendingPathComponent("bounded")).contains(other))
        print("PASS: thumbnail downsampling, alpha, invalid images, persistence, fingerprint invalidation, purge, negative cache and eviction")
    }
}
