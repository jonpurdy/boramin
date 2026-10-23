import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let brand = root.appendingPathComponent("Assets/BoraMinTV.xcassets/AppIcon.brandassets")
for (name, width) in [("TopShelfWide", 2320), ("TopShelf", 1920)] {
    let folder = brand.appendingPathComponent(name + ".imageset")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var images: [[String:String]] = []
    for scale in [1, 2] {
        let w = width * scale, h = 720 * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let size = NSSize(width: 960 * scale, height: 576 * scale)
        let rect = NSRect(x: (CGFloat(w)-size.width)/2, y: (CGFloat(h)-size.height)/2, width: size.width, height: size.height)
        for layer in ["Background", "Middle", "Foreground"] {
            let path = brand.appendingPathComponent("Large.imagestack/\(layer).imagestacklayer/Content.imageset/1.png")
            NSImage(contentsOf: path)!.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(scale).png"))
        images.append(["idiom":"tv", "scale":"\(scale)x", "filename":"\(scale).png"])
    }
    let contents: [String:Any] = ["info":["author":"xcode","version":1],"images":images]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
}
let manifestURL = brand.appendingPathComponent("Contents.json")
var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String:Any]
var assets = manifest["assets"] as! [[String:Any]]
for (name, width, role) in [("TopShelfWide", 2320, "top-shelf-image-wide"), ("TopShelf", 1920, "top-shelf-image")] {
    assets.removeAll { $0["role"] as? String == role }
    assets.append(["filename":name + ".imageset", "idiom":"tv", "role":role, "size":"\(width)x720"])
}
manifest["assets"] = assets
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted,.sortedKeys]).write(to: manifestURL)
