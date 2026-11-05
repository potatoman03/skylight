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

    /// How bright it looks, 0...1, as WCAG measures it.
    public var luminance: Double {
        let linear = { (v: Double) in v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast with another color, 1...21.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Black or white, whichever reads better on this color.
    public var ink: RGB { contrast(with: RGB(0, 0, 0)) > contrast(with: RGB(1, 1, 1)) ? RGB(0, 0, 0) : RGB(1, 1, 1) }

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

/// A picture behind the window, in place of the painted sky: a still image or a GIF.
public struct ThemeImage: Codable, Hashable, Sendable {
    /// A file in the app's Themes folder if `builtIn`, else in your Backgrounds folder.
    public var file: String
    public var builtIn: Bool
    /// The point of the picture to keep in view when it's cropped to the window, 0...1 from the top left.
    public var focusX: Double
    public var focusY: Double
    /// Which part of the picture the sidebar shows while a page covers the rest, 0...1 across it.
    public var sidebarFocusX: Double
    /// 1 fills the window; higher crops in.
    public var zoom: Double
    /// Points of blur.
    public var blur: Double
    /// How far the picture fades toward the window's background, 0...1.
    public var fade: Double

    public init(file: String, builtIn: Bool = false, focusX: Double = 0.5, focusY: Double = 0.5, sidebarFocusX: Double = 0.5,
                zoom: Double = 1, blur: Double = 0, fade: Double = 0) {
        self.file = file
        self.builtIn = builtIn
        self.focusX = focusX
        self.focusY = focusY
        self.sidebarFocusX = sidebarFocusX
        self.zoom = zoom
        self.blur = blur
        self.fade = fade
    }

    public var isAnimated: Bool { file.lowercased().hasSuffix(".gif") }
}

/// A field of characters drifting over the sky, drawn live.
public enum AsciiPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case stars, mist, hearts, meadow, rain, petals, waves, snow, embers, grid, dots, dust, weave, contour

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .stars: "Stars"
        case .mist: "Mist"
        case .hearts: "Hearts"
        case .meadow: "Meadow"
        case .rain: "Code rain"
        case .petals: "Petals"
        case .waves: "Waves"
        case .snow: "Snow"
        case .embers: "Embers"
        case .grid: "Retro grid"
        case .dots: "Halftone"
        case .dust: "Dust"
        case .weave: "Weave"
        case .contour: "Contour lines"
        }
    }

    /// The characters it's drawn in, from faintest to strongest.
    public var glyphs: [Character] {
        switch self {
        case .stars: [".", "·", "'", ":", "+", "*", "✦", "✧"]
        case .mist: [".", "·", ":", "-", "~", "~", "=", "≈"]
        case .hearts: ["·", ".", "+", "✧", "*", "♡", "❤", "♡"]
        case .meadow: [".", ",", "'", "\"", ";", "^", "|", "Y"]
        case .rain: ["0", "1", "7", ":", "=", "+", "<", ">"]
        case .petals: [".", "·", "'", ",", "✿", "❀", "✾", "❁"]
        case .waves: [".", "-", "~", "~", "≈", "≈", "∿", "≋"]
        case .snow: [".", "·", "*", "+", "✻", "✼", "❄", "❅"]
        case .embers: [".", "'", "`", "·", ":", "*", "^", "✦"]
        case .grid: ["·", ".", "-", "=", "+", "|", "#", "#"]
        case .dots: ["·", ".", ":", "o", "O", "0", "@", "#"]
        case .dust: [".", "·", ".", "·", "'", "·", ".", ":"]
        case .weave: ["·", ".", "-", "-", "=", "+", "+", "×"]
        case .contour: ["·", ".", "-", "-", "~", "~", "-", "."]
        }
    }
}

/// A theme's character field: what it draws, and in what color.
public struct AsciiLayer: Codable, Hashable, Sendable {
    public var pattern: AsciiPattern
    public var color: RGB
    /// 0...1.
    public var opacity: Double

    public init(pattern: AsciiPattern, color: RGB, opacity: Double) {
        self.pattern = pattern
        self.color = color
        self.opacity = opacity
    }
}

/// A veil of color over the sidebar, to keep its text readable on a busy picture.
public struct ThemeScrim: Codable, Hashable, Sendable {
    public var color: RGB
    /// 0...1.
    public var opacity: Double

    public init(color: RGB, opacity: Double) {
        self.color = color
        self.opacity = opacity
    }
}

/// The colors of one look (light or dark) of a theme. Optional colors are Automatic when nil:
/// the system's own, for the window's mode.
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
    /// A picture in place of the sky. The sky's colors still show until it loads.
    public var image: ThemeImage?
    public var ascii: AsciiLayer?
    public var scrim: ThemeScrim?
    public var text: RGB?
    public var secondaryText: RGB?
    /// The highlight behind the selected row.
    public var selection: RGB?

    public init(sky: RGB, horizon: RGB, glow: RGB, accent: RGB, sunlight: RGB, rays: Double, glass: Double = 1,
                image: ThemeImage? = nil, ascii: AsciiLayer? = nil, scrim: ThemeScrim? = nil, text: RGB? = nil, secondaryText: RGB? = nil,
                selection: RGB? = nil) {
        self.sky = sky
        self.horizon = horizon
        self.glow = glow
        self.accent = accent
        self.sunlight = sunlight
        self.rays = rays
        self.glass = glass
        self.image = image
        self.ascii = ascii
        self.scrim = scrim
        self.text = text
        self.secondaryText = secondaryText
        self.selection = selection
    }

    /// Turns the colors round the wheel. A picture and the colors you set by hand stay as they are.
    func rotated(by turns: Double) -> ThemePalette {
        var p = self
        p.sky = sky.rotated(by: turns)
        p.horizon = horizon.rotated(by: turns)
        p.glow = glow.rotated(by: turns)
        p.accent = accent.rotated(by: turns)
        p.sunlight = sunlight.rotated(by: turns)
        p.ascii?.color = ascii?.color.rotated(by: turns) ?? .init(0, 0, 0)
        return p
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
    /// The built-in theme this one was copied from, which Reset goes back to.
    public var basedOn: String?

    /// The hue that following themes are drawn in.
    public static let baseHue = 0.58

    public init(id: String = UUID().uuidString, name: String, light: ThemePalette, dark: ThemePalette, followsSpace: Bool, basedOn: String? = nil) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        self.followsSpace = followsSpace
        self.basedOn = basedOn
    }

    public func palette(dark isDark: Bool, spaceHue: Double) -> ThemePalette {
        let palette = isDark ? dark : light
        return followsSpace ? palette.rotated(by: spaceHue - Self.baseHue) : palette
    }

    public var isPreset: Bool { Self.presets.contains { $0.id == id } }

    /// This theme as it was built, keeping its name and id.
    public var reset: SkyTheme? {
        guard let base = Self.preset(basedOn) else { return nil }
        var theme = base
        theme.id = id
        theme.name = name
        theme.basedOn = basedOn
        return theme
    }

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

    public static let presets: [SkyTheme] = skies + asciiThemes + quietThemes

    /// Painted skies.
    public static let skies: [SkyTheme] = [
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

    /// Drawn in characters, live, with nothing to download. Each sets its colors to suit.
    public static let asciiThemes: [SkyTheme] = [
        ascii("ethereal", "Ethereal", .mist,
              light: (("#EDE3F4", "#FBF0F3", "#D8EEF3", "#7A5AC7", "#FFF8EE", 0, 1), ("#3B2F5E", "#6C6190", "#9F86E0", "#FFFFFF", 0.30), "#8A6FD6", 0.55),
              dark: (("#2A2357", "#141030", "#4A3A86", "#C9B6FF", "#DCD2FF", 0, 1), ("#F3EEFF", "#BDB2E2", "#B9A2FF", "#140F33", 0.40), "#C9B6FF", 0.5)),
        ascii("deep-space", "Deep Space", .stars,
              light: (("#E6DDF1", "#F7E9EE", "#D9D8F5", "#6A55C9", "#FFF4E6", 0, 1), ("#37305C", "#6A6291", "#9488E6", "#FFFFFF", 0.30), "#6A55C9", 0.5),
              dark: (("#160B33", "#080414", "#4A1560", "#E48BFF", "#E9B8FF", 0, 1), ("#F2ECFF", "#B3A8D6", "#C77DFF", "#070312", 0.30), "#E7DCFF", 0.85)),
        ascii("pink-princess", "Pink Princess", .hearts,
              light: (("#F9D3E2", "#FFEFF0", "#FFD9C9", "#D1457F", "#FFF3E6", 0, 1), ("#5F2544", "#94587A", "#F06BA3", "#FFFFFF", 0.30), "#E0508F", 0.6),
              dark: (("#5C2A5E", "#2B1236", "#A33D78", "#FFA6CC", "#FFD3A8", 0, 1), ("#FFF0F6", "#E8BBD2", "#FF8FC0", "#2A1030", 0.42), "#FFA6CC", 0.7)),
        ascii("wildwood", "Wildwood", .meadow,
              light: (("#CFE3A8", "#F3F6DC", "#E8E59A", "#3E7D2C", "#FFF7CF", 0, 1), ("#233D18", "#4E6A3C", "#6FA84A", "#FDFFF0", 0.40), "#4C8A33", 0.6),
              dark: (("#0E3A36", "#06191C", "#13504A", "#7FE6B4", "#BFF5E0", 0, 1), ("#EAFBF2", "#A8D5C3", "#5FD6A2", "#051A1A", 0.40), "#7FE6B4", 0.55)),
        ascii("terminal", "Terminal", .rain,
              light: (("#E8F0E4", "#F6F9F2", "#D3E8D0", "#1F7A3D", "#F4FFF0", 0, 1), ("#123A1F", "#44694F", "#4FB06E", "#FFFFFF", 0.30), "#1F7A3D", 0.5),
              dark: (("#061208", "#020604", "#0A2412", "#5CFF8F", "#B8FFCE", 0, 1), ("#D8FFE4", "#86C69A", "#3CCB6E", "#020604", 0.30), "#3CFF7A", 0.7)),
        ascii("sakura", "Sakura", .petals,
              light: (("#FBE4EC", "#FFF5F6", "#FAD7E4", "#C2476F", "#FFF6F0", 0, 1), ("#4E2A3A", "#86596C", "#EE86A8", "#FFFFFF", 0.25), "#E58BA9", 0.7),
              dark: (("#2C2548", "#120F24", "#54305F", "#FFB0C9", "#FFE0B8", 0, 1), ("#FFF1F5", "#D2B8CB", "#FF9DBC", "#13102A", 0.38), "#FFB7CF", 0.7)),
        ascii("tide", "Tide", .waves,
              light: (("#9FDDEB", "#E6FAF7", "#B8F0E4", "#0B7F95", "#FFFBEA", 0, 1), ("#0C3A4A", "#2F6472", "#2FB5C7", "#FFFFFF", 0.42), "#0B8FA8", 0.45),
              dark: (("#0A3A44", "#041A20", "#0E4E55", "#6FEBE0", "#B8FFF4", 0, 1), ("#E9FFFC", "#A6D9D6", "#4FD9D0", "#042023", 0.38), "#6FEBE0", 0.55)),
        ascii("snowfall", "Snowfall", .snow,
              light: (("#DCE8F4", "#F6FAFD", "#E4E8F7", "#2F6FB0", "#FFFFFF", 0, 1), ("#1F2F45", "#566A82", "#7FB0E0", "#FFFFFF", 0.35), "#7FA5CC", 0.7),
              dark: (("#142238", "#080E1A", "#22304F", "#9CCBFF", "#DCEBFF", 0, 1), ("#EAF3FF", "#A9BBD2", "#7FB6F0", "#080E1A", 0.35), "#DCEBFF", 0.7)),
        ascii("ember", "Ember", .embers,
              light: (("#F8D9B8", "#FFF1E0", "#F9C9A8", "#B8451E", "#FFF0D8", 0, 1), ("#4A2310", "#80502F", "#E6763C", "#FFF8EE", 0.38), "#D9602A", 0.6),
              dark: (("#2A0F0A", "#100503", "#5A1E10", "#FF9A55", "#FFC48C", 0, 1), ("#FFEFE2", "#D8B09A", "#FF7A3C", "#100503", 0.30), "#FF8A3C", 0.85)),
        ascii("synthwave", "Synthwave", .grid,
              light: (("#F6D6F2", "#DCE6FF", "#FFD6E8", "#B026A8", "#FFF0FA", 0, 1), ("#3A1648", "#6E4A80", "#D868D0", "#FFFFFF", 0.32), "#B026A8", 0.5),
              dark: (("#1B0B3A", "#070316", "#4A0F5E", "#FF5FD2", "#FFB8EC", 0, 1), ("#F7E8FF", "#B9A2D6", "#FF5FD2", "#070316", 0.32), "#FF5FD2", 0.75)),
        ascii("mono", "Mono", .dots,
              light: (("#E9E9E9", "#F7F7F7", "#EFEFEF", "#222222", "#FFFFFF", 0, 1), ("#111111", "#555555", "#999999", "#FFFFFF", 0.35), "#222222", 0.35),
              dark: (("#141414", "#0A0A0A", "#1E1E1E", "#EDEDED", "#FFFFFF", 0, 1), ("#F2F2F2", "#A6A6A6", "#8C8C8C", "#0A0A0A", 0.30), "#F0F0F0", 0.4)),
        ascii("golden-hour", "Golden Hour", .embers,
              light: (("#FFD9A8", "#FFF0D6", "#FFC4B0", "#A84A16", "#FFF2D0", 0, 1), ("#4A2610", "#7E5230", "#EE9A55", "#FFF8EC", 0.36), "#D9782A", 0.5),
              dark: (("#3A1F14", "#180C08", "#6A2F22", "#FFB870", "#FFD9A0", 0, 1), ("#FFF1E0", "#DDB89A", "#E8904A", "#180C08", 0.32), "#FFB870", 0.6)),
        ascii("matcha", "Matcha", .meadow,
              light: (("#D6E8B4", "#F5F9E6", "#E6F0C4", "#4A7A1E", "#FDFFE8", 0, 1), ("#26381A", "#556B42", "#8DBB5C", "#FBFFF0", 0.38), "#5E9230", 0.55),
              dark: (("#1E2C14", "#0E1609", "#2F4318", "#B8E67C", "#E2F7BE", 0, 1), ("#F0FAE2", "#B2C99A", "#7FB84A", "#0E1609", 0.34), "#B8E67C", 0.5)),
        ascii("midnight", "Midnight", .rain,
              light: (("#DDE6F7", "#F3F6FC", "#CCD9F2", "#2A55B8", "#F6F9FF", 0, 1), ("#14264F", "#4A5D85", "#6F93DD", "#FFFFFF", 0.32), "#2A55B8", 0.45),
              dark: (("#070F24", "#030712", "#0F1F4A", "#7AAEFF", "#C2D8FF", 0, 1), ("#E2ECFF", "#93A8CC", "#3F6FD0", "#030712", 0.30), "#6FA8FF", 0.65)),
        ascii("cotton-candy", "Cotton Candy", .hearts,
              light: (("#F8D7EC", "#DCEBFF", "#FFE3D6", "#A83A88", "#FFF6FA", 0, 1), ("#47264F", "#7A5A85", "#E48BCB", "#FFFFFF", 0.34), "#D66BB8", 0.55),
              dark: (("#3A2450", "#1C1238", "#2F3A78", "#FFB3E0", "#CFE0FF", 0, 1), ("#FFF0FA", "#D3BCDC", "#E28FCB", "#1C1238", 0.38), "#FFB3E0", 0.6)),
        ascii("citrus", "Citrus", .dots,
              light: (("#FFE89A", "#FFF9DC", "#FFD08A", "#A04F00", "#FFFBE0", 0, 1), ("#4A3206", "#7E6228", "#F0B040", "#FFFDF0", 0.40), "#E08A1A", 0.4),
              dark: (("#2E2408", "#151004", "#4A3208", "#FFC83D", "#FFE9A0", 0, 1), ("#FFF7DF", "#D6C28C", "#D9962A", "#151004", 0.34), "#FFC83D", 0.45)),
    ]

    /// Soft colors and faint, slow patterns, for when the theme should stay out of the way.
    public static let quietThemes: [SkyTheme] = [
        ascii("linen", "Linen", .dust,
              light: (("#EFEAE1", "#F8F5EE", "#E8E1D4", "#5E5548", "#FFFDF8", 0, 1), ("#2E2A24", "#6B6459", "#B8AD9A", "#FBF8F2", 0.30), "#8C8272", 0.3),
              dark: (("#26231F", "#1A1815", "#2E2A25", "#D8CDB9", "#F2EADB", 0, 1), ("#EFE9DE", "#A89F90", "#8C8272", "#1A1815", 0.30), "#BDB29F", 0.25)),
        ascii("oat", "Oat", .weave,
              light: (("#F0E6D6", "#FAF4EA", "#EADFCB", "#7E6034", "#FFFBF2", 0, 1), ("#362B1C", "#75664F", "#C9B48F", "#FCF8F0", 0.30), "#A58A60", 0.24),
              dark: (("#2C261D", "#1C1813", "#372F24", "#DBC198", "#F4E6CC", 0, 1), ("#F1EADD", "#B3A68F", "#8A7350", "#1C1813", 0.30), "#DBC198", 0.2)),
        ascii("stone", "Stone", .weave,
              light: (("#E3E1DC", "#F1F0EC", "#DAD8D2", "#55524C", "#FBFAF7", 0, 1), ("#2A2926", "#6A6863", "#A8A59D", "#F5F4F0", 0.30), "#77746D", 0.25),
              dark: (("#2A2927", "#1B1A19", "#33322F", "#CFCBC2", "#ECE9E2", 0, 1), ("#ECEAE5", "#A5A29B", "#77746D", "#1B1A19", 0.30), "#A5A29B", 0.2)),
        ascii("sage", "Sage", .contour,
              light: (("#DDE3D6", "#F1F3EB", "#D3DCCB", "#4E6853", "#F9FBF4", 0, 1), ("#27332A", "#5E6D60", "#9DB19F", "#F6F8F1", 0.30), "#6F8A72", 0.28),
              dark: (("#252C26", "#171C18", "#2E372F", "#AFC9B1", "#DDEBDD", 0, 1), ("#E9EFE8", "#A3B3A4", "#6F8A72", "#171C18", 0.30), "#AFC9B1", 0.22)),
        ascii("moss", "Moss", .dust,
              light: (("#E2E2CF", "#F3F3E7", "#D9DAC2", "#5E6138", "#FBFBF0", 0, 1), ("#2D2E1C", "#66674F", "#AEB08B", "#F8F8EE", 0.30), "#84875A", 0.28),
              dark: (("#262818", "#191A10", "#30321F", "#C6CA99", "#E8EBC8", 0, 1), ("#EEEFDF", "#ABAD91", "#7C7F55", "#191A10", 0.30), "#C6CA99", 0.2)),
        ascii("fog", "Fog", .mist,
              light: (("#DEE3E8", "#F2F4F6", "#D5DBE2", "#4F6B84", "#FAFBFC", 0, 1), ("#252E38", "#5F6C79", "#9FB1C2", "#F6F8FA", 0.30), "#7890A6", 0.3),
              dark: (("#252B32", "#171B20", "#2D343C", "#A9C1D6", "#D9E5EF", 0, 1), ("#E8EDF2", "#A0ADBA", "#6E8699", "#171B20", 0.30), "#A9C1D6", 0.22)),
        ascii("harbor", "Harbor", .waves,
              light: (("#D9E0E6", "#EFF2F4", "#CFD9E0", "#3D5A73", "#F8FAFB", 0, 1), ("#1F2C38", "#566675", "#94ABBD", "#F5F7F9", 0.30), "#5F7D96", 0.26),
              dark: (("#1D2732", "#121920", "#25323E", "#9DB8CE", "#D2E0EC", 0, 1), ("#E6EDF3", "#9AAAB8", "#5F7D96", "#121920", 0.30), "#9DB8CE", 0.2)),
        ascii("clay", "Clay", .contour,
              light: (("#EBDDD2", "#F7F0EA", "#E6D2C4", "#8E5339", "#FFF9F4", 0, 1), ("#3A2A22", "#75604F", "#CFA48F", "#FBF5F0", 0.30), "#B27E66", 0.28),
              dark: (("#30251F", "#1E1714", "#3B2C24", "#DDA88E", "#F3D9C9", 0, 1), ("#F2E8E1", "#B8A597", "#9A6B55", "#1E1714", 0.30), "#DDA88E", 0.22)),
        ascii("mauve", "Mauve", .dust,
              light: (("#E6DFE6", "#F5F1F4", "#DFD5DF", "#7A5C7E", "#FCF9FB", 0, 1), ("#332936", "#6F6272", "#B7A4BA", "#FAF6F9", 0.30), "#957D99", 0.3),
              dark: (("#2C2630", "#1C181F", "#372E3B", "#CDB4D2", "#EADCEE", 0, 1), ("#EFE9F1", "#AFA3B3", "#80698A", "#1C181F", 0.30), "#CDB4D2", 0.22)),
        ascii("sumi", "Sumi", .contour,
              light: (("#EDEDEA", "#F8F8F6", "#E4E4E0", "#2B2B2B", "#FFFFFF", 0, 1), ("#171717", "#5C5C58", "#A6A6A0", "#FBFBF9", 0.30), "#5C5C58", 0.22),
              dark: (("#181818", "#101010", "#202020", "#DEDEDA", "#F4F4F0", 0, 1), ("#EDEDEA", "#9C9C98", "#6C6C68", "#101010", 0.30), "#9C9C98", 0.2)),
    ]

    private typealias Colors = (sky: String, horizon: String, glow: String, accent: String, sunlight: String, rays: Double, glass: Double)

    private typealias Ink = (text: String, secondaryText: String, selection: String, scrim: String, scrimOpacity: Double)

    private static func palette(_ c: Colors) -> ThemePalette {
        ThemePalette(sky: RGB(hex: c.sky)!, horizon: RGB(hex: c.horizon)!, glow: RGB(hex: c.glow)!,
                     accent: RGB(hex: c.accent)!, sunlight: RGB(hex: c.sunlight)!, rays: c.rays, glass: c.glass)
    }

    private static func fixed(_ id: String, _ name: String, light: Colors, dark: Colors) -> SkyTheme {
        SkyTheme(id: id, name: name, light: palette(light), dark: palette(dark), followsSpace: false)
    }

    private static func ascii(_ id: String, _ name: String, _ pattern: AsciiPattern, light: (Colors, Ink, String, Double),
                              dark: (Colors, Ink, String, Double)) -> SkyTheme {
        func look(_ c: (Colors, Ink, String, Double)) -> ThemePalette {
            var p = palette(c.0)
            p.text = RGB(hex: c.1.text)
            p.secondaryText = RGB(hex: c.1.secondaryText)
            p.selection = RGB(hex: c.1.selection)
            p.scrim = ThemeScrim(color: RGB(hex: c.1.scrim)!, opacity: c.1.scrimOpacity)
            p.ascii = AsciiLayer(pattern: pattern, color: RGB(hex: c.2)!, opacity: c.3)
            return p
        }
        return SkyTheme(id: id, name: name, light: look(light), dark: look(dark), followsSpace: false)
    }
}
