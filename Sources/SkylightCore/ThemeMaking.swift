import Foundation

extension ThemeImage {
    /// The kinds of picture a theme can use.
    public static let fileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"]
}

extension ThemePalette {
    /// Colors to suit a picture, from a sample of its pixels. The picture's most common hues set the
    /// sky and accent; the sidebar's veil is as strong as text needs on the picture's busiest parts.
    public static func suited(to pixels: [RGB], dark: Bool, image: ThemeImage? = nil) -> ThemePalette {
        let pixels = pixels.isEmpty ? [RGB(0.5, 0.5, 0.55)] : pixels

        var weights = [Double](repeating: 0, count: 12)
        for pixel in pixels {
            let c = pixel.hsv
            if c.s > 0.08, c.v > 0.2 { weights[min(Int(c.h * 12), 11)] += c.s * c.v }
        }
        let ranked = weights.indices.sorted { weights[$0] > weights[$1] }
        let total = weights.reduce(0, +)
        let hue = (Double(ranked[0]) + 0.5) / 12
        let second = weights[ranked[1]] > 0 ? (Double(ranked[1]) + 0.5) / 12 : hue + 0.08
        // A picture with hardly any color gets a theme with hardly any color.
        let color = min(total / Double(pixels.count) / 0.05, 1)

        var palette: ThemePalette
        if dark {
            palette = ThemePalette(sky: RGB(h: hue, s: 0.45 * color, v: 0.22), horizon: RGB(h: hue, s: 0.45 * color, v: 0.09),
                                   glow: RGB(h: second, s: 0.5 * color, v: 0.3), accent: RGB(h: hue, s: 0.5 * color, v: 1),
                                   sunlight: RGB(h: hue, s: 0.2 * color, v: 1), rays: 0, image: image,
                                   text: RGB(h: hue, s: 0.06 * color, v: 0.98), secondaryText: RGB(h: hue, s: 0.18 * color, v: 0.76),
                                   selection: RGB(h: hue, s: 0.55 * color, v: 0.9))
        } else {
            palette = ThemePalette(sky: RGB(h: hue, s: 0.22 * color, v: 0.96), horizon: RGB(h: hue, s: 0.06 * color, v: 1),
                                   glow: RGB(h: second, s: 0.18 * color, v: 1), accent: RGB(h: hue, s: 0.7 * color, v: 0.55),
                                   sunlight: RGB(h: hue, s: 0.04 * color, v: 1), rays: 0, image: image,
                                   text: RGB(h: hue, s: 0.4 * color, v: 0.16), secondaryText: RGB(h: hue, s: 0.3 * color, v: 0.36),
                                   selection: RGB(h: hue, s: 0.6 * color, v: 0.8))
        }

        // Light text has the most trouble on the picture's brightest parts, dark text on its darkest.
        let brightness = pixels.sorted { $0.luminance < $1.luminance }
        let hardest = brightness[dark ? (brightness.count - 1) * 9 / 10 : (brightness.count - 1) / 10]
        let veil = dark ? RGB(h: hue, s: 0.4 * color, v: 0.08) : RGB(h: hue, s: 0.03 * color, v: 1)
        // Pictures are busier than any sample shows, so the veil starts well above nothing.
        var opacity = 0.5
        while opacity < 0.9, palette.text!.contrast(with: hardest.mixed(with: veil, opacity)) < 4.5 { opacity += 0.05 }
        palette.scrim = ThemeScrim(color: veil, opacity: opacity)
        return palette
    }

    /// Everything in range, and nothing pointing inside the app. Theme files come from anywhere.
    func imported() -> ThemePalette {
        var p = self
        p.rays = Self.clamp(rays, 0...1)
        p.glass = Self.clamp(glass, 0.4...1.4)
        if let image, !image.builtIn {
            p.image?.focusX = Self.clamp(image.focusX, 0...1)
            p.image?.focusY = Self.clamp(image.focusY, 0...1)
            p.image?.sidebarFocusX = Self.clamp(image.sidebarFocusX, 0...1)
            p.image?.zoom = Self.clamp(image.zoom, 1...3)
            p.image?.blur = Self.clamp(image.blur, 0...40)
            p.image?.fade = Self.clamp(image.fade, 0...0.9)
        } else {
            p.image = nil
        }
        p.scrim?.opacity = Self.clamp(scrim?.opacity ?? 0, 0...1)
        p.ascii?.opacity = Self.clamp(ascii?.opacity ?? 0, 0...1)
        return p
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }
}

/// A theme and its pictures in one file, to keep or to pass on.
public struct ThemeFile: Codable, Sendable {
    public static let fileExtension = "skylighttheme"
    /// Bigger than any sensible theme, to stop a wrong file being read into memory.
    public static let sizeLimit = 128 * 1024 * 1024
    private static let currentFormat = 1

    public enum Problem: Error, Equatable { case newerFormat }

    public var format: Int
    public var theme: SkyTheme
    /// Each picture's bytes, by the file name its look refers to.
    public var pictures: [String: Data]

    public init(theme: SkyTheme, pictures: [String: Data]) {
        format = Self.currentFormat
        self.theme = theme
        self.pictures = pictures
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decoded(from data: Data) throws -> ThemeFile {
        let file = try JSONDecoder().decode(ThemeFile.self, from: data)
        guard file.format <= currentFormat else { throw Problem.newerFormat }
        return file
    }

    /// The theme, made safe to keep: a new identity, a sensible name, and values in range.
    /// Its pictures still have to be stored and pointed at.
    public func importedTheme(id: String = UUID().uuidString) -> SkyTheme {
        var theme = theme
        theme.id = id
        let name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        theme.name = name.isEmpty ? "Imported Theme" : String(name.prefix(60))
        if SkyTheme.preset(theme.basedOn) == nil { theme.basedOn = nil }
        theme.light = theme.light.imported()
        theme.dark = theme.dark.imported()
        return theme
    }
}
