import SkylightBrowser
import SkylightCore
import SwiftUI

// MARK: - Previews

/// A tiny Skylight window drawn in a theme's colors: sky, sidebar glass, and a page card.
struct ThemePreview: View {
    let theme: SkyTheme
    let dark: Bool
    var hue: Double = SkyTheme.baseHue

    var body: some View {
        let p = theme.palette(dark: dark, spaceHue: hue)
        let glass = Color.white.opacity((dark ? 0.14 : 0.62) * min(1.4, p.glass))
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(p.sky), Color(p.horizon)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(p.glow).opacity(0.7), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 90)
            RadialGradient(colors: [Color(p.sunlight).opacity(0.25 + p.rays * 0.5), .clear],
                           center: UnitPoint(x: 0.3, y: -0.2), startRadius: 0, endRadius: 70)
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
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// A theme in the gallery: light on the left half, dark on the right, like the two looks it has.
struct ThemeCard: View {
    let theme: SkyTheme
    let selected: Bool
    var hue: Double = SkyTheme.baseHue
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                ZStack {
                    ThemePreview(theme: theme, dark: false, hue: hue)
                    ThemePreview(theme: theme, dark: true, hue: hue)
                        .mask(HStack(spacing: 0) { Color.clear; Color.black })
                }
                .frame(height: compact ? 54 : 76)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .overlay(shape.inset(by: -3).strokeBorder(Color(theme.light.accent), lineWidth: 2).opacity(selected ? 1 : 0))
                .scaleEffect(hovering && !selected ? 1.02 : 1)
                HStack(spacing: 4) {
                    Text(theme.name).font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                    if theme.followsSpace {
                        Image(systemName: "paintpalette").font(.system(size: 9)).foregroundStyle(.tertiary)
                            .help("Follows each Space's color")
                    }
                }
                .padding(.leading, 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
    }
}

/// Every theme, as a grid of cards.
struct ThemeGallery: View {
    let themes: [SkyTheme]
    let selectedID: String?
    var hue: Double = SkyTheme.baseHue
    var compact = false
    let select: (SkyTheme) -> Void
    var create: (() -> Void)?

    var body: some View {
        let width: CGFloat = compact ? 92 : 132
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 40), spacing: compact ? 10 : 14)],
                  alignment: .leading, spacing: compact ? 10 : 16) {
            ForEach(themes) { theme in
                ThemeCard(theme: theme, selected: theme.id == selectedID, hue: hue, compact: compact) { select(theme) }
            }
            if let create {
                Button(action: create) {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(height: 76)
                            .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary))
                        Text("New Theme").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Settings › Appearance

struct AppearanceSettings: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        @Bindable var prefs = browser.preferences
        let hue = browser.store.state.activeSpace.hue
        let current = prefs.theme(prefs.themeID) ?? .standard

        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SettingsBlock("Mode") {
                    HStack(spacing: 14) {
                        ForEach(Preferences.Appearance.allCases) { mode in
                            ModeCard(mode: mode, theme: current, hue: hue, selected: prefs.appearance == mode) {
                                prefs.appearance = mode
                            }
                        }
                    }
                }

                SettingsBlock("Theme", note: "Changes every Space. A Space can have its own theme from its menu or Spaces settings.") {
                    ThemeGallery(themes: prefs.themes, selectedID: prefs.themeID, hue: hue, select: { theme in
                        animate(Motion.swap) { prefs.themeID = theme.id }
                    }, create: { newTheme(from: current) })
                }

                ThemeEditor(theme: current, hue: hue, duplicate: { newTheme(from: current) })

                SettingsBlock("Interface") {
                    VStack(spacing: 0) {
                        SettingsRow("Light through the sky") { Toggle("", isOn: $prefs.godRays).toggleStyle(.switch).controlSize(.small).labelsHidden() }
                        Divider()
                        SettingsRow("Tab rows") {
                            Picker("", selection: $prefs.density) {
                                ForEach(Preferences.Density.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                        }
                        Divider()
                        SettingsRow("Page corners") {
                            HStack {
                                Slider(value: $prefs.cornerRadius, in: 0...22, step: 1).frame(width: 200)
                                Text("\(Int(prefs.cornerRadius)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                            }
                        }
                    }
                    .settingsCard()
                }

                SettingsBlock("Sidebar", note: "The Space's tabs and the Space switcher always show.") {
                    VStack(spacing: 0) {
                        ForEach(Array(Preferences.SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                            if i > 0 { Divider() }
                            SettingsRow(item.name) {
                                Toggle("", isOn: Binding(get: { prefs.shows(item) },
                                                         set: { on in animate(Motion.swap) { prefs.setShows(item, on) } }))
                                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            }
                        }
                        Divider()
                        SettingsRow("Hide the whole sidebar") { Toggle("", isOn: $prefs.sidebarCollapsed).toggleStyle(.switch).controlSize(.small).labelsHidden() }
                    }
                    .settingsCard()
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
    }

    private func newTheme(from base: SkyTheme) {
        var copy = base
        copy.id = UUID().uuidString
        copy.name = base.isPreset ? "My \(base.name)" : "\(base.name) copy"
        let saved = browser.preferences.saveTheme(copy)
        animate(Motion.swap) { browser.preferences.themeID = saved.id }
    }
}

/// Light, Dark or System, each shown in the current theme.
private struct ModeCard: View {
    let mode: Preferences.Appearance
    let theme: SkyTheme
    let hue: Double
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                Group {
                    switch mode {
                    case .light: ThemePreview(theme: theme, dark: false, hue: hue)
                    case .dark: ThemePreview(theme: theme, dark: true, hue: hue)
                    case .system:
                        ZStack {
                            ThemePreview(theme: theme, dark: false, hue: hue)
                            ThemePreview(theme: theme, dark: true, hue: hue).mask(HStack(spacing: 0) { Color.clear; Color.black })
                        }
                    }
                }
                .frame(width: 132, height: 76)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .overlay(shape.inset(by: -3).strokeBorder(.tint, lineWidth: 2).opacity(selected ? 1 : 0))
                Text(mode.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).padding(.leading, 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Edits a theme of your own in place, live. Presets offer to make an editable copy.
private struct ThemeEditor: View {
    let theme: SkyTheme
    let hue: Double
    let duplicate: () -> Void
    @Environment(Browser.self) private var browser
    @State private var showAdvanced = false

    var body: some View {
        SettingsBlock("Customize \(theme.name)") {
            if theme.isPreset {
                HStack {
                    Text("Built-in themes can't be changed. Make a copy to choose your own colors.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Customize…", action: duplicate)
                }
                .padding(14)
                .settingsCard()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow("Name") {
                        TextField("", text: binding(\.name)).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    Divider()
                    SettingsRow("Follow each Space's color", note: "Colors turn to match whichever Space is showing.") {
                        Toggle("", isOn: binding(\.followsSpace)).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        PaletteEditor(title: "Light", palette: binding(\.light), advanced: showAdvanced)
                        Divider()
                        PaletteEditor(title: "Dark", palette: binding(\.dark), advanced: showAdvanced)
                    }
                    Divider()
                    HStack {
                        Button(showAdvanced ? "Fewer Colors" : "More Colors") { animate(Motion.swap) { showAdvanced.toggle() } }
                            .buttonStyle(.link)
                        Spacer()
                        Button("Duplicate", action: duplicate)
                        Button("Delete", role: .destructive) {
                            animate(Motion.swap) { browser.preferences.deleteTheme(theme.id) }
                        }
                    }
                    .padding(12)
                }
                .settingsCard()
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<SkyTheme, T>) -> Binding<T> {
        Binding(get: { (browser.preferences.theme(theme.id) ?? theme)[keyPath: path] },
                set: { value in
                    var updated = browser.preferences.theme(theme.id) ?? theme
                    updated[keyPath: path] = value
                    browser.preferences.saveTheme(updated)
                })
    }
}

private struct PaletteEditor: View {
    let title: String
    @Binding var palette: ThemePalette
    let advanced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            color("Sky", \.sky)
            color("Horizon", \.horizon)
            color("Accent", \.accent)
            if advanced {
                color("Glow", \.glow)
                color("Sunlight", \.sunlight)
                slider("Light", \.rays, 0...1)
                slider("Glass", \.glass, 0.4...1.4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ name: String, _ path: WritableKeyPath<ThemePalette, RGB>) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(palette[keyPath: path].hex).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            ColorPicker("", selection: Binding(get: { Color(palette[keyPath: path]) },
                                               set: { palette[keyPath: path] = RGB($0) }), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func slider(_ name: String, _ path: WritableKeyPath<ThemePalette, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(name)
            Spacer()
            Slider(value: Binding(get: { palette[keyPath: path] }, set: { palette[keyPath: path] = $0 }), in: range)
                .frame(width: 120)
        }
    }
}

// MARK: - Quick theme popover

/// The paintbrush in the sidebar: pick a theme and mode without leaving the page.
struct QuickThemePanel: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        @Bindable var prefs = browser.preferences
        let space = browser.store.state.activeSpace
        let own = space.themeID != nil
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $prefs.appearance) {
                ForEach(Preferences.Appearance.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("", selection: Binding(get: { own }, set: { onlyHere in
                animate(Motion.swap) {
                    _ = browser.store.send(.setSpaceTheme(space.id, onlyHere ? (space.themeID ?? prefs.themeID) : nil))
                }
            })) {
                Text("All Spaces").tag(false)
                Text("Only \(space.name)").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ThemeGallery(themes: prefs.themes, selectedID: own ? space.themeID : prefs.themeID, hue: space.hue,
                         compact: true) { theme in
                animate(Motion.swap) {
                    if own { _ = browser.store.send(.setSpaceTheme(space.id, theme.id)) } else { prefs.themeID = theme.id }
                }
            }

            HStack {
                Toggle("Light through the sky", isOn: $prefs.godRays).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button("More…") { browser.openSettings("appearance") }.buttonStyle(.link)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 330)
    }
}

// MARK: - Layout helpers

/// A titled group on a settings page.
struct SettingsBlock<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let accessory: Accessory

    init(_ title: String, note: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.note = note
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension View {
    func settingsCard() -> some View {
        background(.primary.opacity(0.035), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }
}
