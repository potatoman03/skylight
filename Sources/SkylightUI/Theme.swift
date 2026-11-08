import AppKit
import SkylightCore
import SwiftUI

enum Theme {
    static func skyTop(_ hue: Double, _ scheme: ColorScheme) -> Color {
        let h = hue - floor(hue)
        return scheme == .dark ? Color(hue: h, saturation: 0.55, brightness: 0.40) : Color(hue: h, saturation: 0.42, brightness: 0.98)
    }

    static func skyBottom(_ hue: Double, _ scheme: ColorScheme) -> Color {
        let h = (hue + 0.06) - floor(hue + 0.06)
        return scheme == .dark ? Color(hue: h, saturation: 0.50, brightness: 0.16) : Color(hue: h, saturation: 0.16, brightness: 1)
    }

    /// A Space's color, for its icon and accents.
    static func accent(_ hue: Double, _ scheme: ColorScheme = .light) -> Color {
        let h = hue - floor(hue)
        return scheme == .dark ? Color(hue: h, saturation: 0.45, brightness: 1) : Color(hue: h, saturation: 0.75, brightness: 0.62)
    }

    /// A Space's color washed through the sidebar: brighter than its accent, so it reads as light
    /// falling on the glass rather than paint.
    static func wash(_ hue: Double, _ scheme: ColorScheme) -> Color {
        let h = hue - floor(hue)
        return scheme == .dark ? Color(hue: h, saturation: 0.6, brightness: 0.75) : Color(hue: h, saturation: 0.65, brightness: 0.95)
    }

    /// A round swatch for menus, which draw only images in color, not SwiftUI shapes.
    @MainActor
    static func swatch(_ hue: Double, _ scheme: ColorScheme) -> NSImage { swatch(accent(hue, scheme)) }

    /// A folder's label, the same colors as a Space's.
    static func folder(_ color: FolderColor, _ scheme: ColorScheme) -> Color {
        color.hue.map { accent($0, scheme) } ?? .gray
    }

    static func swatch(_ swatch: Color) -> NSImage {
        let color = NSColor(swatch)
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

extension RGB {
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

/// A Space's icon: an SF Symbol name, an emoji, or else the first letter of its name.
struct SpaceIcon: View {
    let icon: String?
    var name: String = ""
    var size: CGFloat = 13

    var body: some View {
        if let icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
            Image(systemName: icon).font(.system(size: size, weight: .medium))
        } else if let icon {
            Text(icon).font(.system(size: size))
        } else {
            Text(name.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: size * 0.95, weight: .bold, design: .rounded))
        }
    }
}

/// Site icons, loaded once per URL.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()
    private var images: [URL: NSImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { images[url] }

    func image(for url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        if failed.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { images[url] = image } else { failed.insert(url) }
        return image
    }
}

/// A site's logo: the icon the page declared, or else one fetched from the site itself, so tabs
/// you haven't opened yet still show their logo. Skylight's own pages get a symbol.
struct Favicon: View {
    let url: URL?
    var page: URL? = nil
    let title: String
    var size: CGFloat = 16
    @State private var image: NSImage?

    var body: some View {
        Group {
            if page?.isSkylightPage == true {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.gray.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: size * 0.22, style: .continuous))
                    .transition(Arrive(scale: 0.8))
            } else {
                Text(title.first.map { String($0).uppercased() } ?? "•")
                    .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        // Before it shows, so a row rebuilt for any reason never flashes its letter.
        .onAppear {
            guard image == nil else { return }
            image = Self.candidates(icon: url, page: page, large: size > 18).lazy.compactMap(FaviconCache.shared.cached).first
        }
        .task(id: [url, page]) {
            let candidates = Self.candidates(icon: url, page: page, large: size > 18)
            for candidate in candidates {
                if let cached = FaviconCache.shared.cached(candidate) { image = cached; return }
            }
            for candidate in candidates {
                if let loaded = await FaviconCache.shared.image(for: candidate) {
                    animate(Motion.arrive) { image = loaded }
                    return
                }
            }
            image = nil
        }
    }

    /// Big tiles prefer the touch icon (sharp at any size); rows prefer the small favicon.
    static func candidates(icon: URL?, page: URL?, large: Bool) -> [URL] {
        var urls: [URL] = icon.map { [$0] } ?? []
        guard let page, let scheme = page.scheme, scheme == "https" || scheme == "http", let host = page.host(),
              let root = URL(string: "\(scheme)://\(host)\(page.port.map { ":\($0)" } ?? "")") else { return urls }
        let touch = root.appending(path: "apple-touch-icon.png"), ico = root.appending(path: "favicon.ico")
        urls += large ? [touch, ico] : [ico, touch]
        return urls
    }
}
