// Draws the disk image's window: Skylight Default's dawn, the name, and a line of light from the
// app to Applications. `scripts/dmg.sh` runs it; it writes a 1x and a 2x PNG.
//
//   swift scripts/dmg-background.swift Resources/Themes/skylight-default-light.jpg OUT_DIR
import AppKit

let size = CGSize(width: 660, height: 420)
/// Where Finder centers the two icons, from the top left. `dmg.sh` puts them here.
let app = CGPoint(x: 170, y: 228), applications = CGPoint(x: 490, y: 228)

let args = CommandLine.arguments
guard args.count == 3, let picture = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift PICTURE OUT_DIR\n".utf8))
    exit(1)
}

func render(scale: CGFloat) -> Data {
    let pixels = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Top-left origin, like Finder's coordinates.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    // The picture, its ribbons crossing between the two icons, so the light sits on the way across.
    let source = picture.size
    let fill: CGFloat = 0.64
    let shown = CGSize(width: 1586 * fill, height: 992 * fill)
    let cross = CGPoint(x: 0.61 * shown.width, y: 0.55 * shown.height)
    let origin = CGPoint(x: (app.x + applications.x) / 2 - cross.x, y: app.y - 18 - cross.y)
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y + shown.height)
    ctx.scaleBy(x: 1, y: -1)
    picture.draw(in: CGRect(origin: .zero, size: shown), from: CGRect(origin: .zero, size: source), operation: .copy, fraction: 1)
    ctx.restoreGState()

    // Morning haze over the top, where the name sits.
    let haze = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 0.7), CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(haze, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 170), options: [])

    // Dusk along the bottom, so Finder's names under the icons read in light mode and dark.
    let dusk = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.3, green: 0.36, blue: 0.76, alpha: 0), CGColor(red: 0.3, green: 0.36, blue: 0.76, alpha: 0.68)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(dusk, start: CGPoint(x: 0, y: app.y + 24), end: CGPoint(x: 0, y: app.y + 84), options: [.drawsAfterEndLocation])

    // The name, in New York, and what to do.
    func text(_ string: String, size points: CGFloat, serif: Bool, color: NSColor, y: CGFloat, kern: CGFloat = 0) {
        var font = NSFont.systemFont(ofSize: points, weight: serif ? .regular : .medium)
        if serif, let descriptor = font.fontDescriptor.withDesign(.serif) { font = NSFont(descriptor: descriptor, size: points) ?? font }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let line = NSAttributedString(string: string, attributes: attributes)
        let width = line.size().width
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        line.draw(at: CGPoint(x: (size.width - width) / 2, y: size.height - y - line.size().height))
        ctx.restoreGState()
    }
    text("Skylight", size: 38, serif: true, color: NSColor(red: 0.08, green: 0.1, blue: 0.17, alpha: 1), y: 44, kern: 0.5)
    text("Drag it into Applications", size: 13, serif: false, color: NSColor(red: 0.27, green: 0.31, blue: 0.41, alpha: 0.85), y: 96, kern: 0.2)

    // A line of light from one icon to the other, brightest where the ribbons cross.
    let from = app.x + 74, to = applications.x - 74, y = app.y
    let beam = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0.2)] as CFArray,
                          locations: [0, 0.35, 0.7, 1])!
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 8, color: CGColor(red: 1, green: 0.85, blue: 0.8, alpha: 0.9))
    ctx.addRect(CGRect(x: from, y: y - 0.75, width: to - from, height: 1.5))
    ctx.clip()
    ctx.drawLinearGradient(beam, start: CGPoint(x: from, y: y), end: CGPoint(x: to, y: y), options: [])
    ctx.restoreGState()
    // Its head: a small chevron of light.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 6, color: CGColor(gray: 1, alpha: 0.9))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    ctx.setLineWidth(1.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: to - 8, y: y - 6))
    ctx.addLine(to: CGPoint(x: to, y: y))
    ctx.addLine(to: CGPoint(x: to - 8, y: y + 6))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render(scale: 1).write(to: out.appending(path: "background.png"))
try render(scale: 2).write(to: out.appending(path: "background@2x.png"))
