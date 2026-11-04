// Draws Skylight's app icon, a window in the roof with light falling through it, and writes
// Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "Skylight-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The mark, drawn on a 664 × 380 grid (y down): the skylight's frame and the beam of light.
enum Mark {
    static let size = CGSize(width: 664, height: 380)
    static let frame: [CGPoint] = [.init(x: 205, y: 0), .init(x: 664, y: 0), .init(x: 492, y: 380), .init(x: 0, y: 380)]
    static let opening: [CGPoint] = [.init(x: 229, y: 41), .init(x: 599, y: 41), .init(x: 465, y: 339), .init(x: 70, y: 339)]
    /// From the top right corner of the opening, widening to the sill.
    static let beam: [CGPoint] = [.init(x: 572, y: 30), .init(x: 575, y: 30), .init(x: 330, y: 350), .init(x: 158, y: 350)]
}

func polygon(_ points: [CGPoint], in path: CGMutablePath, _ transform: CGAffineTransform) {
    path.addLines(between: points.map { $0.applying(transform) })
    path.closeSubpath()
}

func draw(pixels: Int) -> Data {
    let s = CGFloat(pixels) / 1024
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // The tile: macOS's icon grid puts an 824 pt rounded square in the 1024 pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(.white)
    ctx.fillPath()
    ctx.restoreGState()

    // A pale morning sky on the tile.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        CGColor(srgbRed: 0.90, green: 0.93, blue: 1, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // The mark, centered, its grid flipped to CoreGraphics' y-up.
    let width: CGFloat = 600
    let scale = width / Mark.size.width
    let height = Mark.size.height * scale
    let transform = CGAffineTransform(translationX: (1024 - width) / 2, y: (1024 + height) / 2 - 8)
        .scaledBy(x: scale, y: -scale)
    let mark = CGMutablePath()
    polygon(Mark.frame, in: mark, transform)
    polygon(Mark.opening, in: mark, transform)
    let beam = CGMutablePath()
    polygon(Mark.beam, in: beam, transform)

    ctx.addPath(mark)
    ctx.clip(using: .evenOdd)
    let blue = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(srgbRed: 0.13, green: 0.32, blue: 1, alpha: 1),
        CGColor(srgbRed: 0.0, green: 0.16, blue: 0.82, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(blue, start: CGPoint(x: 0, y: 760), end: CGPoint(x: 0, y: 260), options: [])
    ctx.resetClip()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(beam)
    ctx.clip()
    ctx.drawLinearGradient(blue, start: CGPoint(x: 0, y: 760), end: CGPoint(x: 0, y: 260), options: [])
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try draw(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}

let resources = root.appending(path: "Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try draw(pixels: 1024).write(to: resources.appending(path: "AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
