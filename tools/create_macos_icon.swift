#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Compile the shared Icon Composer artwork into Sequoia-compatible Mac assets.
// Keep transparent padding around the rendered shape rather than flattening it.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BoraMinIcon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe(); process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "BoraMinIcon", code: Int(process.terminationStatus))
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let developer = try run("/usr/bin/xcode-select", ["-p"])
let renderer = URL(fileURLWithPath: developer).deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
let rendered = temporary.appendingPathComponent("rendered.png")
_ = try run(renderer.path, [root.appendingPathComponent("Assets/BoraMin.icon").path,
    "--export-image", "--output-file", rendered.path, "--platform", "macOS",
    "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"])
guard let source = CGImageSourceCreateWithURL(rendered as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { fatalError("Cannot load rendered icon") }

let folder = root.appendingPathComponent("MacOS/Assets.xcassets/AppIcon.appiconset")
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create icon bitmap") }
        context.interpolationQuality = .high
        let side = CGFloat(pixels)
        let bounds = CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
        context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.018,
                          color: CGColor(gray: 0, alpha: 0.25))
        context.draw(artwork, in: bounds)
        guard let image = context.makeImage() else { fatalError("Cannot render icon") }
        let output = folder.appendingPathComponent("icon_\(points)x\(points)@\(scale)x.png")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Cannot write icon")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finish icon") }
        print("Generated \(output.lastPathComponent): \(pixels)×\(pixels), transparent padding")
    }
}
