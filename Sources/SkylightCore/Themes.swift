import Foundation

/// An sRGB color, 0...1 per channel. Saved as `"#RRGGBB"`.
public struct RGB: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Hue, saturation and brightness, each 0...1.
    public init(h: Double, s: Double, v: Double) {
        let h = (h - floor(h)) * 6
        let k = { (n: Double) -> Double in
            let k = (n + h).truncatingRemainder(dividingBy: 6)
            return v - v * s * max(0, min(k, 4 - k, 1))
        }
        self.init(k(5), k(3), k(1))
    }

    public var hex: String {
        let c = { (x: Double) in Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    public var hsv: (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    /// The same color turned round the color wheel.
    public func rotated(by turns: Double) -> RGB {
        let c = hsv
        return RGB(h: c.h + turns, s: c.s, v: c.v)
    }

    public func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = RGB(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a #RRGGBB color: \(text)"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// The colors of one look (light or dark) of a theme.
public struct ThemePalette: Codable, Hashable, Sendable {
    /// The top of the sky.
    public var sky: RGB
    /// The bottom of the sky.
    public var horizon: RGB
    /// A second color that drifts in from the right.
    public var glow: RGB
    /// Selection and controls.
    public var accent: RGB
    /// The color of the light falling through the sky.
    public var sunlight: RGB
    /// How strong the light is, 0...1.
    public var rays: Double
    /// How solid the frosted surfaces are: 1 is standard, lower is clearer.
    public var glass: Double

    public init(sky: RGB, horizon: RGB, glow: RGB, accent: RGB, sunlight: RGB, rays: Double, glass: Double = 1) {
        self.sky = sky
        self.horizon = horizon
        self.glow = glow
        self.accent = accent
        self.sunlight = sunlight
        self.rays = rays
        self.glass = glass
    }

    func rotated(by turns: Double) -> ThemePalette {
        ThemePalette(sky: sky.rotated(by: turns), horizon: horizon.rotated(by: turns), glow: glow.rotated(by: turns),
                     accent: accent.rotated(by: turns), sunlight: sunlight.rotated(by: turns), rays: rays, glass: glass)
    }
}

/// A look for the whole window: the sky, the light in it, the glass on it, in light and dark.
///
/// A theme can follow each Space's color: its palettes are drawn for a blue Space and turn round
/// the color wheel to match whichever Space is showing. Or it can keep its own colors everywhere.
public struct SkyTheme: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var light: ThemePalette
    public var dark: ThemePalette
    public var followsSpace: Bool

    /// The hue that following themes are drawn in.
    public static let baseHue = 0.58

    public init(id: String = UUID().uuidString, name: String, light: ThemePalette, dark: ThemePalette, followsSpace: Bool) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        self.followsSpace = followsSpace
    }

    public func palette(dark isDark: Bool, spaceHue: Double) -> ThemePalette {
        let palette = isDark ? dark : light
        return followsSpace ? palette.rotated(by: spaceHue - Self.baseHue) : palette
    }

    public var isPreset: Bool { Self.presets.contains { $0.id == id } }

    public static func preset(_ id: String?) -> SkyTheme? { presets.first { $0.id == id } }

    // MARK: - Presets

    public static let standard = SkyTheme(
        id: "sky", name: "Sky",
        light: ThemePalette(sky: RGB(h: 0.58, s: 0.42, v: 0.98), horizon: RGB(h: 0.64, s: 0.16, v: 1),
                            glow: RGB(h: 0.50, s: 0.22, v: 1), accent: RGB(h: 0.58, s: 0.75, v: 0.62),
                            sunlight: RGB(1, 0.985, 0.94), rays: 0.55),
        dark: ThemePalette(sky: RGB(h: 0.60, s: 0.55, v: 0.40), horizon: RGB(h: 0.67, s: 0.50, v: 0.16),
                           glow: RGB(h: 0.52, s: 0.55, v: 0.28), accent: RGB(h: 0.58, s: 0.45, v: 1),
                           sunlight: RGB(h: 0.70, s: 0.35, v: 1), rays: 0.30),
        followsSpace: true)

    public static let presets: [SkyTheme] = [
        standard,
        SkyTheme(
            id: "pastel", name: "Pastel",
            light: ThemePalette(sky: RGB(h: 0.58, s: 0.24, v: 1), horizon: RGB(h: 0.66, s: 0.07, v: 1),
                                glow: RGB(h: 0.48, s: 0.14, v: 1), accent: RGB(h: 0.58, s: 0.6, v: 0.66),
                                sunlight: RGB(1, 0.99, 0.96), rays: 0.45, glass: 1.05),
            dark: ThemePalette(sky: RGB(h: 0.60, s: 0.32, v: 0.36), horizon: RGB(h: 0.67, s: 0.30, v: 0.15),
                               glow: RGB(h: 0.52, s: 0.34, v: 0.27), accent: RGB(h: 0.58, s: 0.32, v: 1),
                               sunlight: RGB(h: 0.70, s: 0.2, v: 1), rays: 0.25),
            followsSpace: true),
        SkyTheme(
            id: "vivid", name: "Vivid",
            light: ThemePalette(sky: RGB(h: 0.58, s: 0.64, v: 0.95), horizon: RGB(h: 0.62, s: 0.26, v: 1),
                                glow: RGB(h: 0.47, s: 0.42, v: 1), accent: RGB(h: 0.58, s: 0.85, v: 0.6),
                                sunlight: RGB(1, 0.97, 0.9), rays: 0.65, glass: 0.95),
            dark: ThemePalette(sky: RGB(h: 0.60, s: 0.78, v: 0.46), horizon: RGB(h: 0.66, s: 0.72, v: 0.18),
                               glow: RGB(h: 0.50, s: 0.72, v: 0.34), accent: RGB(h: 0.58, s: 0.55, v: 1),
                               sunlight: RGB(h: 0.70, s: 0.45, v: 1), rays: 0.4),
            followsSpace: true),
        fixed("paper", "Paper",
              light: ("#EDE5D8", "#FAF7F1", "#F3E4CF", "#A0522D", "#FFF8EC", 0.22, 1.05),
              dark: ("#2B2724", "#191715", "#3A2E26", "#E2A468", "#FFE2C0", 0.14, 1)),
        fixed("graphite", "Graphite",
              light: ("#D9DCE1", "#F5F6F8", "#E5E7EB", "#3B6FD8", "#FFFFFF", 0.2, 1),
              dark: ("#2A2C30", "#141518", "#34373D", "#8AB4FF", "#DDE6FF", 0.1, 1)),
        fixed("dusk", "Dusk",
              light: ("#C5B3F2", "#FFE6D6", "#FFC2CF", "#7B4FD1", "#FFF1E0", 0.6, 1),
              dark: ("#33245C", "#140D26", "#6A2C5A", "#FF9F7A", "#FFB38A", 0.4, 1)),
        fixed("forest", "Forest",
              light: ("#BBD9C2", "#F2F7EE", "#E2EEC6", "#2F7D4F", "#FFFBEA", 0.5, 1),
              dark: ("#17352A", "#0A1712", "#2C3F1E", "#8FD6A6", "#E9F5C8", 0.3, 1)),
        fixed("ocean", "Ocean",
              light: ("#9AD6E8", "#EEFAFB", "#C0F0E2", "#0A7C99", "#F4FFFD", 0.55, 1),
              dark: ("#0F3A4A", "#061419", "#0E4A48", "#6FD3E8", "#C8F4FF", 0.35, 1)),
        fixed("rose", "Rosé",
              light: ("#F4C1D0", "#FFF2F4", "#FFD9C2", "#C2416B", "#FFF4EE", 0.5, 1),
              dark: ("#46202F", "#1A0B12", "#5A2A2A", "#FF9DB8", "#FFC9C2", 0.32, 1)),
        fixed("aurora", "Aurora",
              light: ("#B5E5D6", "#F3F0FF", "#D8C8FF", "#1F8A70", "#F6FFFB", 0.55, 1),
              dark: ("#0B1E33", "#050A14", "#14503F", "#7CF0C4", "#B8FFE6", 0.45, 1)),
    ]

    private typealias Colors = (sky: String, horizon: String, glow: String, accent: String, sunlight: String, rays: Double, glass: Double)

    private static func fixed(_ id: String, _ name: String, light: Colors, dark: Colors) -> SkyTheme {
        func palette(_ c: Colors) -> ThemePalette {
            ThemePalette(sky: RGB(hex: c.sky)!, horizon: RGB(hex: c.horizon)!, glow: RGB(hex: c.glow)!,
                         accent: RGB(hex: c.accent)!, sunlight: RGB(hex: c.sunlight)!, rays: c.rays, glass: c.glass)
        }
        return SkyTheme(id: id, name: name, light: palette(light), dark: palette(dark), followsSpace: false)
    }
}
