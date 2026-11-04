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

        Form {
            Section {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(Preferences.Appearance.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Tab rows", selection: $prefs.density) {
                    ForEach(Preferences.Density.allCases) { Text($0.name).tag($0) }
                }
                ForEach(Preferences.SidebarItem.choices, id: \.self) { item in
                    Toggle(item.name, isOn: Binding(get: { prefs.shows(item) }, set: { prefs.setShows(item, $0) }))
                }
                Toggle("Hide the sidebar", isOn: $prefs.sidebarCollapsed)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("The Space's tabs and the Space switcher always show.")
            }

            Section {
                Toggle("Outline the focused pane", isOn: $prefs.highlightFocusedPane)
            } header: {
                Text("Split View")
            } footer: {
                Text("Drag a tab onto the page to split it. Drag a pane's grip to move it, or a divider to resize.")
            }

            Section {
                Toggle("Show sound controls on tabs", isOn: $prefs.showMediaControls)
                Toggle("Picture in Picture when you leave a playing video", isOn: $prefs.autoPictureInPicture)
            } header: {
                Text("Media")
            } footer: {
                Text("Picture in Picture: ⌥⌘P.")
            }

            Section {
                Toggle("Sky behind the sidebar", isOn: $prefs.skyBackdrop)
                if prefs.skyBackdrop {
                    Toggle("Light through the sky", isOn: $prefs.godRays)
                    ThemeGallery(themes: prefs.themes, selectedID: prefs.themeID, hue: hue, compact: true, select: { theme in
                        prefs.themeID = theme.id
                    }, create: { newTheme(from: current) })
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Sky")
            } footer: {
                Text("A Space can have its own sky from its settings in Spaces.")
            }

            if prefs.skyBackdrop {
                ThemeEditor(theme: current, duplicate: { newTheme(from: current) })
            }
        }
        .formStyle(.grouped)
    }

    private func newTheme(from base: SkyTheme) {
        var copy = base
        copy.id = UUID().uuidString
        copy.name = base.isPreset ? "My \(base.name)" : "\(base.name) copy"
        let saved = browser.preferences.saveTheme(copy)
        browser.preferences.themeID = saved.id
    }
}

/// Edits a sky of your own in place, live. Built-in ones offer to make an editable copy.
private struct ThemeEditor: View {
    let theme: SkyTheme
    let duplicate: () -> Void
    @Environment(Browser.self) private var browser
    @State private var showAdvanced = false

    var body: some View {
        if theme.isPreset {
            Section("Customize \(theme.name)") {
                LabeledContent("Built-in skies can't be changed.") {
                    Button("Customize…", action: duplicate)
                }
            }
        } else {
            Section("Customize \(theme.name)") {
                TextField("Name", text: binding(\.name))
                Toggle("Follow each Space's color", isOn: binding(\.followsSpace))
                Toggle("More colors", isOn: $showAdvanced)
            }
            PaletteEditor(title: "Light", palette: binding(\.light), advanced: showAdvanced)
            PaletteEditor(title: "Dark", palette: binding(\.dark), advanced: showAdvanced)
            Section {
                HStack {
                    Spacer()
                    Button("Duplicate", action: duplicate)
                    Button("Delete Sky", role: .destructive) { browser.preferences.deleteTheme(theme.id) }
                }
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
        Section(title) {
            color("Sky", \.sky)
            color("Horizon", \.horizon)
            color("Accent", \.accent)
            if advanced {
                color("Glow", \.glow)
                color("Sunlight", \.sunlight)
                Slider(value: $palette.rays, in: 0...1) { Text("Light") }
                Slider(value: $palette.glass, in: 0.4...1.4) { Text("Glass") }
            }
        }
    }

    private func color(_ name: String, _ path: WritableKeyPath<ThemePalette, RGB>) -> some View {
        ColorPicker(selection: Binding(get: { Color(palette[keyPath: path]) }, set: { palette[keyPath: path] = RGB($0) }),
                    supportsOpacity: false) {
            LabeledContent(name, value: palette[keyPath: path].hex)
        }
    }
}
