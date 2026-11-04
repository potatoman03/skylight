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
            HalfAndHalf { ThemePreview(theme: theme, dark: false, hue: hue) } dark: { ThemePreview(theme: theme, dark: true, hue: hue) }
        } action: { action() }
        .help(theme.followsSpace ? "\(theme.name), in each Space's color" : theme.name)
    }
}

// MARK: - Settings › Appearance

struct AppearanceSettings: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @State private var customizing = false

    var body: some View {
        @Bindable var prefs = browser.preferences
        let hue = browser.store.state.activeSpace.hue
        let current = prefs.theme(prefs.themeID) ?? .standard
        let dark = prefs.appearance == .dark || (prefs.appearance == .system && scheme == .dark)

        Form {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    labeled("Mode") {
                        HStack(spacing: 14) {
                            ForEach(Preferences.Appearance.allCases) { mode in
                                ChoiceCard(title: mode.name, selected: prefs.appearance == mode) {
                                    switch mode {
                                    case .light: WindowSketch(dark: false)
                                    case .dark: WindowSketch(dark: true)
                                    case .system: HalfAndHalf { WindowSketch(dark: false) } dark: { WindowSketch(dark: true) }
                                    }
                                } action: { prefs.appearance = mode }
                            }
                        }
                    }
                    labeled("Background") {
                        HStack(spacing: 14) {
                            ChoiceCard(title: "Glass", selected: !prefs.skyBackdrop) {
                                WindowSketch(dark: dark)
                            } action: { animate(Motion.travel) { prefs.skyBackdrop = false } }
                            ChoiceCard(title: "Sky", selected: prefs.skyBackdrop) {
                                ThemePreview(theme: current, dark: dark, hue: hue)
                            } action: { animate(Motion.travel) { prefs.skyBackdrop = true } }
                            // Keeps the two cards the width of the mode cards above.
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text(prefs.skyBackdrop ? "A Space can have its own sky, from Spaces." : "Glass lets your desktop show softly through the sidebar.")
            }

            if prefs.skyBackdrop {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 170), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(prefs.themes) { theme in
                            ThemeCard(theme: theme, selected: theme.id == current.id, hue: hue) { prefs.themeID = theme.id }
                        }
                        ChoiceCard(title: "New Sky", selected: false, height: 72) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary))
                        } action: {
                            newTheme(from: current)
                            customizing = true
                        }
                    }
                    .padding(.vertical, 6)
                    Toggle("Light through the sky", isOn: $prefs.godRays)
                    LabeledContent(current.isPreset ? "\(current.name) is built in" : "Colors of \(current.name)") {
                        Button(current.isPreset ? "Customize…" : "Edit Colors…") {
                            if current.isPreset { newTheme(from: current) }
                            customizing = true
                        }
                    }
                } header: {
                    Text("Sky")
                }
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
        }
        .formStyle(.grouped)
        .sheet(isPresented: $customizing) {
            let theme = browser.preferences.theme(browser.preferences.themeID) ?? .standard
            VStack(spacing: 0) {
                Form {
                    ThemeEditor(theme: theme, duplicate: { newTheme(from: theme) }, deleted: { customizing = false })
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Done") { customizing = false }.keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            .frame(width: 460, height: 520)
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
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
    var deleted: () -> Void = {}
    @Environment(Browser.self) private var browser
    @State private var showAdvanced = false

    var body: some View {
        let live = browser.preferences.theme(theme.id) ?? theme
        Section {
            HalfAndHalf { ThemePreview(theme: live, dark: false) } dark: { ThemePreview(theme: live, dark: true) }
                .frame(height: 110)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }
        if theme.isPreset {
            Section("Customize \(theme.name)") {
                LabeledContent("Built-in skies can't be changed.") {
                    Button("Customize…", action: duplicate)
                }
            }
        } else {
            Section {
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
                    Button("Delete Sky", role: .destructive) {
                        browser.preferences.deleteTheme(theme.id)
                        deleted()
                    }
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
