import AppKit
import SkylightCore
import SwiftUI

/// The window's ground: the desktop, blurred, tinted with the active Space's hue.
struct SpaceBackdrop: View {
    let hue: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            BehindWindowBlur()
            LinearGradient(
                colors: [Theme.tint(hue, scheme, 0), Theme.tint(hue + 0.04, scheme, 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .motion(Motion.hue, value: hue)
        .ignoresSafeArea()
    }
}

enum Theme {
    static func tint(_ hue: Double, _ scheme: ColorScheme, _ stop: Int) -> Color {
        let h = hue.truncatingRemainder(dividingBy: 1)
        if scheme == .dark {
            return Color(hue: h, saturation: stop == 0 ? 0.45 : 0.55, brightness: stop == 0 ? 0.32 : 0.22).opacity(0.78)
        }
        return Color(hue: h, saturation: stop == 0 ? 0.32 : 0.42, brightness: stop == 0 ? 0.98 : 0.9).opacity(0.72)
    }

    /// A Space's dot in the switcher.
    static func dot(_ hue: Double) -> Color { Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.85) }

    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 9
}

struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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

struct Favicon: View {
    let url: URL?
    let title: String
    var size: CGFloat = 16
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
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
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = FaviconCache.shared.cached(url) { image = cached; return }
            let loaded = await FaviconCache.shared.image(for: url)
            animate(Motion.arrive) { image = loaded }
        }
    }
}
