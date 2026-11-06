import SkylightBrowser
import SkylightCore
import SwiftUI

// MARK: - Previews

/// A tiny Skylight window drawn in a theme's colors: sky, sidebar glass, and a page card.
struct ThemePreview: View {
    let theme: SkyTheme
    let dark: Bool
    var hue: Double = SkyTheme.baseHue
    /// The little window on the sky; without it the preview is just a swatch of the theme.
    var showsWindow = true
    @Environment(Browser.self) private var browser

    var body: some View {
        let p = theme.palette(dark: dark, spaceHue: hue)
        let glass = Color.white.opacity((dark ? 0.14 : 0.62) * min(1.4, p.glass))
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(p.sky), Color(p.horizon)], startPoint: .top, endPoint: .bottom)
            if let image = p.image, let url = browser.preferences.url(for: image) {
                ThemeImageView(url: url, image: image, scale: 0.15, thumbnail: true)
            } else if let ascii = p.ascii {
                AsciiSample(layer: ascii, columns: showsWindow ? 110 : 40, rows: showsWindow ? 34 : 12)
            } else {
                RadialGradient(colors: [Color(p.glow).opacity(0.7), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 90)
                RadialGradient(colors: [Color(p.sunlight).opacity(0.25 + p.rays * 0.5), .clear],
                               center: UnitPoint(x: 0.3, y: -0.2), startRadius: 0, endRadius: 70)
            }
            if showsWindow {
                HStack(alignment: .top, spacing: 5) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 2.5) {
                            ForEach(0..<3) { _ in Circle().fill(.primary.opacity(0.18)).frame(width: 4, height: 4) }
                        }
                        .padding(.bottom, 2)
                        RoundedRectangle(cornerRadius: 3).fill(glass).frame(height: 8)
                        RoundedRectangle(cornerRadius: 3).fill(Color(p.accent).opacity(0.85)).frame(width: 18, height: 5)
                        ForEach(0..<3) { i in
                            RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(i == 0 ? 0.22 : 0.12))
                                .frame(width: [26, 22, 28][i], height: 4)
                        }
                    }
                    .frame(width: 34)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(dark ? Color(white: 0.12) : .white)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                RoundedRectangle(cornerRadius: 1.5).fill(Color(p.accent)).frame(width: 20, height: 4)
                                RoundedRectangle(cornerRadius: 1.5).fill(.primary.opacity(0.12)).frame(width: 34, height: 3)
                                RoundedRectangle(cornerRadius: 1.5).fill(.primary.opacity(0.08)).frame(width: 26, height: 3)
                            }
                            .padding(6)
                        }
                        .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 3, y: 1)
                        // Leave sky showing below and beside the card, so both looks of the sky read.
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                        .padding(.trailing, 4)
                }
                .padding(6)
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// A few lines of a pattern's characters, for previews.
private struct AsciiSample: View {
    let layer: AsciiLayer
    let columns: Int
    let rows: Int

    var body: some View {
        let glyphs = layer.pattern.glyphs
        let line = { (row: Int) in
            String((0..<columns).map { ($0 + row) % 2 == 0 ? " " : glyphs[($0 * 5 + row * 3 + $0 / 3) % glyphs.count] })
        }
        // In an overlay, so the text's width doesn't stretch the card.
        Color.clear.overlay(alignment: .topLeading) {
            Text((0..<rows).map(line).joined(separator: "\n"))
                .font(.system(size: 8, design: .monospaced))
                .lineLimit(rows)
                .fixedSize()
                .foregroundStyle(Color(layer.color).opacity(min(layer.opacity + 0.15, 1)))
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// A choice shown as a picture with its name under it, ringed and ticked when chosen, like the
/// appearance choices in System Settings.
struct ChoiceCard<Preview: View>: View {
    let title: String
    let selected: Bool
    var height: CGFloat = 64
    var badge: String? = nil
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                preview()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                    .overlay(shape.inset(by: -3.5).strokeBorder(Color.accentColor, lineWidth: 2.5).opacity(selected ? 1 : 0))
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(5)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .scaleEffect(hovering && !selected ? 1.025 : 1)
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                    if let badge { Image(systemName: badge).font(.system(size: 9)).foregroundStyle(.tertiary) }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .animation(Motion.resolved(Motion.feedback), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A plain Skylight window, drawn small: translucent sidebar, toolbar and a page.
struct WindowSketch: View {
    let dark: Bool

    var body: some View {
        let ink = Color.primary
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    ForEach(0..<3) { _ in Circle().fill(ink.opacity(0.2)).frame(width: 4, height: 4) }
                }
                .padding(.bottom, 3)
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.75)).frame(width: 24, height: 5)
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.13)).frame(width: [20, 26, 16][i], height: 4)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(width: 44, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(dark ? Color(white: 0.2) : Color(white: 0.9))
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.16)).frame(width: 30, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.08)).frame(maxWidth: .infinity).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.08)).frame(width: 38, height: 4)
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dark ? Color(white: 0.11) : .white)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// Shows `light` on the left and `dark` on the right, split down the middle.
struct HalfAndHalf<Light: View, Dark: View>: View {
    @ViewBuilder let light: () -> Light
    @ViewBuilder let dark: () -> Dark

    var body: some View {
        ZStack {
            light()
            dark().mask(HStack(spacing: 0) { Color.clear; Color.black })
        }
    }
}

/// A theme in the gallery: light on the left half, dark on the right, like the two looks it has.
struct ThemeCard: View {
    let theme: SkyTheme
    let selected: Bool
    var hue: Double = SkyTheme.baseHue
    let action: () -> Void

    var body: some View {
        ChoiceCard(title: theme.name, selected: selected, height: 72, badge: theme.followsSpace ? "paintpalette" : nil) {
            HalfAndHalf {
                ThemePreview(theme: theme, dark: false, hue: hue, showsWindow: false)
            } dark: {
                ThemePreview(theme: theme, dark: true, hue: hue, showsWindow: false)
            }
        } action: { action() }
        .help(theme.followsSpace ? "\(theme.name), in each Space's color" : theme.name)
    }
}

// MARK: - Settings › Themes

/// One thing to do here: pick a theme, for every Space or for one of them.
struct AppearanceSettings: View {
    @Environment(Browser.self) private var browser
    /// The Space being themed, or nil for all of them.
    @State private var scope: SpaceID?

    private static let columns = [GridItem(.adaptive(minimum: 128, maximum: 170), spacing: 14)]

    var body: some View {
        @Bindable var prefs = browser.preferences
        let spaces = browser.store.state.spaces
        let space = spaces.first { $0.id == scope }

        Form {
            Section {
                if spaces.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ScopeChip(title: "All Spaces", selected: space == nil) {
                                Image(systemName: "square.stack")
                            } action: { scope = nil }
                            ForEach(spaces) { item in
                                ScopeChip(title: item.name, selected: item.id == space?.id) {
                                    SpaceIcon(icon: item.icon, name: item.name, size: 12)
                                } action: { scope = item.id }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                VStack(alignment: .leading, spacing: 20) {
                    if let space { followAll(space, prefs) }
                    if !prefs.customThemes.isEmpty {
                        labeled("Yours") {
                            grid {
                                ForEach(prefs.customThemes) { theme in
                                    card(theme, space, prefs)
                                        .contextMenu {
                                            Button("Delete", role: .destructive) { prefs.deleteTheme(theme.id) }
                                        }
                                }
                            }
                        }
                    }
                    group("Pictures", SkyTheme.pictureThemes, space, prefs)
                    group("Quiet", SkyTheme.quietThemes, space, prefs)
                    group("Playful", SkyTheme.asciiThemes, space, prefs)
                    labeled("Skies") {
                        grid {
                            // Glass is no theme at all, so it's for the whole window or nothing.
                            if space == nil {
                                ChoiceCard(title: "Glass", selected: !prefs.skyBackdrop, height: 72) {
                                    WindowSketch(dark: false)
                                } action: { animate(Motion.travel) { prefs.skyBackdrop = false } }
                            }
                            ForEach(SkyTheme.skies) { card($0, space, prefs) }
                        }
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text(space.map { "Only \($0.name) changes." } ?? "Every Space uses this, unless you give it its own.")
            }
        }
        .formStyle(.grouped)
    }

    private func followAll(_ space: Space, _ prefs: Preferences) -> some View {
        grid {
            ChoiceCard(title: "Same as All Spaces", selected: space.themeID == nil, height: 72) {
                if prefs.skyBackdrop {
                    let theme = prefs.theme(prefs.themeID) ?? .standard
                    HalfAndHalf {
                        ThemePreview(theme: theme, dark: false, hue: space.hue, showsWindow: false)
                    } dark: {
                        ThemePreview(theme: theme, dark: true, hue: space.hue, showsWindow: false)
                    }
                } else {
                    WindowSketch(dark: false)
                }
            } action: { browser.store.send(.setSpaceTheme(space.id, nil)) }
        }
    }

    private func group(_ title: String, _ themes: [SkyTheme], _ space: Space?, _ prefs: Preferences) -> some View {
        labeled(title) {
            grid { ForEach(themes) { card($0, space, prefs) } }
        }
    }

    private func card(_ theme: SkyTheme, _ space: Space?, _ prefs: Preferences) -> some View {
        let current = prefs.theme(prefs.themeID) ?? .standard
        let selected = space.map { $0.themeID == theme.id } ?? (prefs.skyBackdrop && theme.id == current.id)
        return ThemeCard(theme: theme, selected: selected, hue: (space ?? browser.store.state.activeSpace).hue) {
            if let space {
                browser.store.send(.setSpaceTheme(space.id, theme.id))
            } else {
                animate(Motion.travel) {
                    prefs.skyBackdrop = true
                    prefs.themeID = theme.id
                }
            }
        }
    }

    private func grid(@ViewBuilder content: () -> some View) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14, content: content)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }
}

/// All Spaces, or one of them: what picking a theme changes.
private struct ScopeChip<Icon: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(selected ? Color.accentColor : Color.primary.opacity(0.06), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
