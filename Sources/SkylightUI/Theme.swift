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

    /// Shadows take the sky's color, so nothing gets a grey halo.
    static func shadow(_ hue: Double, _ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.35) : Color(hue: hue - floor(hue), saturation: 0.6, brightness: 0.45).opacity(0.16)
    }

    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
}

/// Surfaces on the sky: frosted white in the day, faint light at night, with a hairline of light
/// on the edge instead of a dark border.
enum Surface {
    case selected, hover, resting, field

    func fill(_ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch self {
        case .selected: return .white.opacity(dark ? 0.15 : 0.78)
        case .hover: return .white.opacity(dark ? 0.08 : 0.42)
        case .resting: return .white.opacity(dark ? 0.06 : 0.4)
        case .field: return .white.opacity(dark ? 0.09 : 0.6)
        }
    }

    func edge(_ scheme: ColorScheme) -> Color {
        switch self {
        case .selected, .field: .white.opacity(scheme == .dark ? 0.14 : 0.9)
        case .hover, .resting: .white.opacity(scheme == .dark ? 0.06 : 0.5)
        }
    }
}

struct SurfaceBackground: ViewModifier {
    let surface: Surface?
    var radius: CGFloat = Theme.rowRadius
    var lifted = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            if let surface {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                shape.fill(surface.fill(scheme))
                    .overlay(shape.strokeBorder(surface.edge(scheme), lineWidth: 0.75))
                    .shadow(color: lifted ? .black.opacity(scheme == .dark ? 0.25 : 0.06) : .clear, radius: 3, y: 1)
            }
        }
    }
}

extension View {
    func surface(_ surface: Surface?, radius: CGFloat = Theme.rowRadius, lifted: Bool = false) -> some View {
        modifier(SurfaceBackground(surface: surface, radius: radius, lifted: lifted))
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
