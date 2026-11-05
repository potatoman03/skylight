import SkylightBrowser
import SkylightCore
import SwiftUI
import UniformTypeIdentifiers

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

/// Three favorites, drawn small, in a tile style.
private struct TileSketch: View {
    let style: Preferences.FavoriteStyle
    let hue: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let surface: Color = style == .tinted ? Theme.accent(hue, scheme).opacity(0.28) : .white.opacity(scheme == .dark ? 0.14 : 0.75)
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill([Color.red, .blue, .green][i].opacity(0.8))
                        .frame(width: 12, height: 12)
                        .frame(width: 32, height: 28)
                        .background {
                            if style != .plain {
                                shape.fill(surface)
                                shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                            }
                        }
                }
            }
        }
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

// MARK: - Settings › Appearance

struct AppearanceSettings: View {
    @Environment(Browser.self) private var browser
    @State private var customizing = false
    @State private var problem: String?
    @State private var dropping = false

    var body: some View {
        @Bindable var prefs = browser.preferences
        let hue = browser.store.state.activeSpace.hue
        let current = prefs.theme(prefs.themeID) ?? .standard

        Form {
            Section {
                Picker("Mode", selection: $prefs.appearance) {
                    ForEach(Preferences.Appearance.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 20) {
                    labeled("Yours") {
                        LazyVGrid(columns: Self.galleryColumns, alignment: .leading, spacing: 14) {
                            ForEach(prefs.customThemes) { theme in
                                card(theme, current: current, hue: hue, prefs)
                                    .contextMenu {
                                        Button("Edit…") {
                                            pick(theme, prefs)
                                            customizing = true
                                        }
                                        Button("Export…") { export(theme) }
                                        Divider()
                                        Button("Delete", role: .destructive) { prefs.deleteTheme(theme.id) }
                                    }
                            }
                            ChoiceCard(title: "Add Theme", selected: false, height: 72) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .overlay(Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(.secondary))
                            } action: { add(ThemePanels.chooseThemeSource().map { [$0] } ?? []) }
                            .help("A picture, a GIF or a .\(ThemeFile.fileExtension) file")
                        }
                    }
                    labeled("Pictures") {
                        LazyVGrid(columns: Self.galleryColumns, alignment: .leading, spacing: 14) {
                            ForEach(SkyTheme.pictureThemes) { card($0, current: current, hue: hue, prefs) }
                        }
                    }
                    labeled("Quiet") {
                        LazyVGrid(columns: Self.galleryColumns, alignment: .leading, spacing: 14) {
                            ForEach(SkyTheme.quietThemes) { card($0, current: current, hue: hue, prefs) }
                        }
                    }
                    labeled("Playful") {
                        LazyVGrid(columns: Self.galleryColumns, alignment: .leading, spacing: 14) {
                            ForEach(SkyTheme.asciiThemes) { card($0, current: current, hue: hue, prefs) }
                        }
                    }
                    labeled("Skies") {
                        LazyVGrid(columns: Self.galleryColumns, alignment: .leading, spacing: 14) {
                            ChoiceCard(title: "Glass", selected: !prefs.skyBackdrop, height: 72) {
                                WindowSketch(dark: false)
                            } action: { animate(Motion.travel) { prefs.skyBackdrop = false } }
                            ForEach(SkyTheme.skies) { card($0, current: current, hue: hue, prefs) }
                        }
                    }
                }
                .padding(.vertical, 6)
                .dropDestination(for: URL.self) { urls, _ in
                    add(urls)
                    return true
                } isTargeted: { dropping = $0 }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 2)
                        .opacity(dropping ? 1 : 0)
                        .allowsHitTesting(false)
                }
                if prefs.skyBackdrop {
                    LabeledContent(current.name) {
                        Button(current.isPreset ? "Customize…" : "Edit…") {
                            if current.isPreset { newTheme(from: current) }
                            customizing = true
                        }
                    }
                    Toggle("Fill new tabs with the theme", isOn: $prefs.sceneOnNewTab)
                    Toggle("Light through the sky", isOn: $prefs.godRays)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text(problem ?? "Drop a picture or a .\(ThemeFile.fileExtension) file here to add it. A Space can have its own theme, from Spaces.")
            }

            Section {
                Picker("Tab rows", selection: $prefs.density) {
                    ForEach(Preferences.Density.allCases) { Text($0.name).tag($0) }
                }
                Picker("Space header", selection: $prefs.spaceHeaderStyle) {
                    ForEach(Preferences.SpaceHeaderStyle.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Show the Space's ··· button only on hover", isOn: $prefs.spaceMenuOnHover)
                    .disabled(prefs.spaceHeaderStyle == .hidden)
                Picker("Space switcher", selection: $prefs.spaceBarStyle) {
                    ForEach(Preferences.SpaceBarStyle.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Show hints in empty sections", isOn: $prefs.showsDropHints)
                ForEach(Preferences.SidebarItem.choices) { item in
                    Picker(item.name, selection: Binding(get: { prefs.visibility(item) }, set: { prefs.setVisibility(item, $0) })) {
                        ForEach(item.visibilityChoices) { Text($0.name).tag($0) }
                    }
                }
                Toggle("Hide the sidebar", isOn: $prefs.sidebarCollapsed)
            } header: {
                Text("Sidebar")
            } footer: {
                Text(sidebarFooter(prefs))
            }
            Section {
                ForEach(prefs.sidebarOrder) { section in
                    LabeledContent(section.name) {
                        HStack(spacing: 2) {
                            moveButton(section, by: -1, label: "up", symbol: "chevron.up", prefs)
                            moveButton(section, by: 1, label: "down", symbol: "chevron.down", prefs)
                        }
                    }
                }
            } header: {
                Text("Sidebar order")
            } footer: {
                Text("Favorites go above or below your tabs.")
            }
            if prefs.visibility(.favorites) != .hidden {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        labeled("Tiles") {
                            HStack(spacing: 14) {
                                ForEach(Preferences.FavoriteStyle.allCases) { style in
                                    ChoiceCard(title: style.name, selected: prefs.favoriteStyle == style) {
                                        TileSketch(style: style, hue: hue)
                                    } action: { animate(Motion.travel) { prefs.favoriteStyle = style } }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    Picker("Size", selection: $prefs.favoriteSize) {
                        ForEach(Preferences.FavoriteSize.allCases) { Text($0.name).tag($0) }
                    }
                    Picker("Tiles per row", selection: $prefs.favoritesPerRow) {
                        Text("Automatic").tag(0)
                        ForEach(3...6, id: \.self) { Text("\($0)").tag($0) }
                    }
                } header: {
                    Text("Favorites")
                }
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
            ThemeEditor(theme: theme, duplicate: { newTheme(from: theme) }, deleted: { customizing = false }, done: { customizing = false })
                .frame(width: 520, height: 640)
        }
    }

    private static let galleryColumns = [GridItem(.adaptive(minimum: 128, maximum: 170), spacing: 14)]

    private func card(_ theme: SkyTheme, current: SkyTheme, hue: Double, _ prefs: Preferences) -> some View {
        ThemeCard(theme: theme, selected: prefs.skyBackdrop && theme.id == current.id, hue: hue) { pick(theme, prefs) }
    }

    private func pick(_ theme: SkyTheme, _ prefs: Preferences) {
        animate(Motion.travel) {
            prefs.skyBackdrop = true
            prefs.themeID = theme.id
        }
    }

    /// Adds pictures and theme files, shows the last one added, and offers it for editing if it
    /// came from a picture, whose colors are only a first guess.
    private func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let prefs = browser.preferences
        var added: SkyTheme?
        var fromPicture = false
        var failures = 0
        for url in urls {
            let isThemeFile = url.pathExtension.lowercased() == ThemeFile.fileExtension
            if let theme = isThemeFile ? prefs.importTheme(from: url) : prefs.makeTheme(fromPicture: url) {
                added = theme
                fromPicture = !isThemeFile
            } else {
                failures += 1
            }
        }
        problem = failures == 0 ? nil : "Skylight couldn't read \(failures == 1 ? "that file" : "\(failures) of those files")."
        guard let added else { return }
        pick(added, prefs)
        if fromPicture, urls.count == 1 { customizing = true }
    }

    private func export(_ theme: SkyTheme) {
        guard let url = ThemePanels.chooseExportDestination(named: theme.name) else { return }
        problem = browser.preferences.exportTheme(theme.id, to: url) ? nil : "Skylight couldn't save that theme."
    }

    private func moveButton(_ section: SidebarSection, by offset: Int, label: String, symbol: String, _ prefs: Preferences) -> some View {
        let moved = prefs.sidebarOrder.moving(section, by: offset)
        return Button {
            animate(Motion.travel) { prefs.sidebarOrder = moved }
        } label: {
            Image(systemName: symbol).frame(width: 20, height: 20).contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(moved == prefs.sidebarOrder)
        .accessibilityLabel("Move \(section.name) \(label)")
    }

    private func sidebarFooter(_ prefs: Preferences) -> String {
        var notes = ["Each Space's icon, color and tint are in its ··· menu."]
        if prefs.spaceHeaderStyle == .hidden { notes.append("Customize Space… is also in the Tabs menu.") }
        if prefs.spaceBarStyle == .hidden { notes.append("Switch Spaces with ⌃1–9 or ⌥⌘← and ⌥⌘→.") }
        return notes.joined(separator: " ")
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
        copy.basedOn = base.isPreset ? base.id : base.basedOn
        let saved = browser.preferences.saveTheme(copy)
        browser.preferences.themeID = saved.id
    }
}

/// The file panels themes use.
@MainActor
private enum ThemePanels {
    static var themeFile: UTType { UTType(filenameExtension: ThemeFile.fileExtension) ?? .json }

    static func choosePicture() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture or GIF"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseThemeSource() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, themeFile]
        panel.message = "Choose a picture, a GIF or a Skylight theme"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExportDestination(named name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [themeFile]
        panel.nameFieldStringValue = "\(name).\(ThemeFile.fileExtension)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Edits a theme of your own in place, live: both its looks are saved together, and the window
/// behind changes as you go. Built-in ones offer to make an editable copy.
private struct ThemeEditor: View {
    let theme: SkyTheme
    let duplicate: () -> Void
    var deleted: () -> Void = {}
    let done: () -> Void
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @State private var dark: Bool?
    @State private var problem: String?
    @State private var showsColors = false

    var body: some View {
        let live = browser.preferences.theme(theme.id) ?? theme
        let showing = dark ?? (scheme == .dark)
        let path: WritableKeyPath<SkyTheme, ThemePalette> = showing ? \.dark : \.light
        VStack(spacing: 0) {
            preview(live, dark: showing, palette: binding(path))
                .frame(height: 170)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                .padding([.horizontal, .top], 16)
            Picker("Look", selection: Binding(get: { showing }, set: { dark = $0 })) {
                Text("Light").tag(false)
                Text("Dark").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .padding(.top, 12)
            Form {
                if theme.isPreset {
                    Section {
                        LabeledContent("Built-in themes can't be changed.") {
                            Button("Save a Copy", action: duplicate)
                        }
                    }
                } else {
                    Section {
                        TextField("Name", text: binding(\.name))
                    }
                    PictureEditor(palette: binding(path), problem: $problem)
                    AsciiEditor(palette: binding(path))
                    Section {
                        LabeledContent("Colors") {
                            HStack {
                                if live[keyPath: path].image != nil {
                                    Button("Match Picture") {
                                        browser.preferences.matchColors(of: theme.id, dark: showing)
                                    }
                                    .help("Pick this look's colors again to suit its picture")
                                }
                                Button(showsColors ? "Hide" : "Edit…") { animate(Motion.travel) { showsColors.toggle() } }
                            }
                        }
                        if showsColors { Toggle("Follow each Space's color", isOn: binding(\.followsSpace)) }
                    }
                    if showsColors { PaletteEditor(palette: binding(path)) }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !theme.isPreset {
                    Menu {
                        Button("Save a Copy", action: duplicate)
                        Button("Export…", action: export)
                        if let reset = live.reset {
                            Button("Reset to \(SkyTheme.preset(live.basedOn)?.name ?? "Original")") {
                                browser.preferences.saveTheme(reset)
                                browser.preferences.pruneBackgrounds()
                            }
                            .disabled(reset == live)
                        }
                        Divider()
                        Button("Delete Theme", role: .destructive) {
                            browser.preferences.deleteTheme(theme.id)
                            deleted()
                        }
                    } label: {
                        Text("More")
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }

    private func export() {
        guard let url = ThemePanels.chooseExportDestination(named: (browser.preferences.theme(theme.id) ?? theme).name) else { return }
        problem = browser.preferences.exportTheme(theme.id, to: url) ? nil : "Skylight couldn't save that theme."
    }

    /// The look being edited; with a picture, drag to choose what stays in view.
    @ViewBuilder
    private func preview(_ live: SkyTheme, dark: Bool, palette: Binding<ThemePalette>) -> some View {
        // A picture shows whole, so you can see what you're framing.
        let base = ThemePreview(theme: live, dark: dark, showsWindow: palette.wrappedValue.image == nil)
        if palette.wrappedValue.image != nil, !theme.isPreset {
            base.modifier(FocusDrag(palette: palette))
                .help("Drag to choose which part of the picture stays in view")
        } else {
            base
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

/// Dragging moves the picture under the pointer, as it would in the window.
private struct FocusDrag: ViewModifier {
    @Binding var palette: ThemePalette
    @State private var start: CGPoint?

    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 2).onChanged { value in
            guard var image = palette.image else { return }
            let from = start ?? CGPoint(x: image.focusX, y: image.focusY)
            start = from
            image.focusX = min(max(from.x - value.translation.width / 300, 0), 1)
            image.focusY = min(max(from.y - value.translation.height / 150, 0), 1)
            palette.image = image
        }
        .onEnded { _ in start = nil })
    }
}

/// A look's picture and how it sits in the window.
private struct PictureEditor: View {
    @Binding var palette: ThemePalette
    @Binding var problem: String?
    @Environment(Browser.self) private var browser

    var body: some View {
        Section {
            LabeledContent("Picture") {
                HStack {
                    if palette.image != nil {
                        Button("Remove") {
                            palette.image = nil
                            browser.preferences.pruneBackgrounds()
                        }
                    }
                    Button(palette.image == nil ? "Choose…" : "Replace…", action: choose)
                }
            }
            if palette.image != nil {
                DisclosureGroup("Adjust") {
                    slider("Sidebar position", \.sidebarFocusX, 0...1)
                    slider("Zoom", \.zoom, 1...3)
                    slider("Blur", \.blur, 0...40)
                    slider("Fade", \.fade, 0...0.9)
                }
            }
        } footer: {
            Text(problem ?? "An image or GIF, for this look only. Drag the preview to reposition it.")
        }
    }

    private func slider(_ name: String, _ path: WritableKeyPath<ThemeImage, Double>, _ range: ClosedRange<Double>) -> some View {
        Slider(value: Binding(get: { palette.image?[keyPath: path] ?? range.lowerBound },
                              set: { palette.image?[keyPath: path] = $0 }), in: range) { Text(name) }
    }

    private func choose() {
        guard let url = ThemePanels.choosePicture() else { return }
        guard let image = browser.preferences.importBackground(from: url) else {
            problem = "Skylight can't show that file."
            return
        }
        problem = nil
        palette.image = image
        browser.preferences.pruneBackgrounds()
    }
}

/// A look's field of characters.
private struct AsciiEditor: View {
    @Binding var palette: ThemePalette

    var body: some View {
        Section {
            Picker("Pattern", selection: Binding(get: { palette.ascii?.pattern }, set: { pattern in
                palette.ascii = pattern.map { AsciiLayer(pattern: $0, color: palette.ascii?.color ?? palette.accent, opacity: palette.ascii?.opacity ?? 0.5) }
            })) {
                Text("None").tag(AsciiPattern?.none)
                ForEach(AsciiPattern.allCases) { Text($0.name).tag(Optional($0)) }
            }
            if let layer = palette.ascii {
                LabeledContent("Color") {
                    ColorField(color: Binding(get: { layer.color }, set: { palette.ascii?.color = $0 }))
                }
                Slider(value: Binding(get: { layer.opacity }, set: { palette.ascii?.opacity = $0 }), in: 0.1...1) { Text("Strength") }
            }
        }
    }
}

/// Every color of a look, grouped by what it paints.
private struct PaletteEditor: View {
    @Binding var palette: ThemePalette

    var body: some View {
        Section("Surfaces") {
            token("Sky", \.sky)
            token("Horizon", \.horizon)
            token("Glow", \.glow)
            token("Light", \.sunlight)
            Slider(value: $palette.rays, in: 0...1) { Text("Light strength") }
            optional("Sidebar veil", Binding(get: { palette.scrim?.color }, set: { color in
                palette.scrim = color.map { ThemeScrim(color: $0, opacity: palette.scrim?.opacity ?? 0.3) }
            }), fallback: palette.sky)
            if palette.scrim != nil {
                Slider(value: Binding(get: { palette.scrim?.opacity ?? 0 }, set: { palette.scrim?.opacity = $0 }), in: 0...1) {
                    Text("Veil strength")
                }
            }
        }
        Section("Controls") {
            token("Accent", \.accent)
            optional("Selected row", $palette.selection, fallback: palette.accent)
        }
        Section("Text and Icons") {
            optional("Text", $palette.text, fallback: palette.horizon)
            optional("Secondary text", $palette.secondaryText, fallback: palette.horizon)
        }
    }

    private func token(_ name: String, _ path: WritableKeyPath<ThemePalette, RGB>) -> some View {
        LabeledContent(name) { ColorField(color: $palette[dynamicMember: path]) }
    }

    private func optional(_ name: String, _ color: Binding<RGB?>, fallback: RGB) -> some View {
        LabeledContent(name) {
            HStack(spacing: 10) {
                if let value = color.wrappedValue {
                    ColorField(color: Binding(get: { value }, set: { color.wrappedValue = $0 }))
                }
                Toggle("Automatic", isOn: Binding(get: { color.wrappedValue == nil }, set: { color.wrappedValue = $0 ? nil : fallback }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

/// A color as a hex field and a swatch that opens the color picker.
private struct ColorField: View {
    @Binding var color: RGB
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Hex", text: $text)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .frame(width: 66)
                .onSubmit(commit)
            ColorPicker("Color", selection: Binding(get: { Color(color) }, set: { color = RGB($0) }), supportsOpacity: false)
                .labelsHidden()
        }
        .onAppear { text = color.hex }
        .onChange(of: color) { text = color.hex }
    }

    private func commit() {
        if let parsed = RGB(hex: text) { color = parsed } else { text = color.hex }
    }
}
