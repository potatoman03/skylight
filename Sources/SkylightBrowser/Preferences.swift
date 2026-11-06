import AppKit
import Foundation
import ImageIO
import Observation
import SkylightCore

/// Settings that aren't browser state. Saved to `preferences.json` on every change.
@MainActor
@Observable
public final class Preferences {
    public enum SearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
        case google, duckDuckGo, kagi, bing, perplexity, brave, ecosia, startpage, chatGPT
        /// Your own, from `customSearchTemplate`.
        case custom

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .google: "Google"
            case .duckDuckGo: "DuckDuckGo"
            case .kagi: "Kagi"
            case .bing: "Bing"
            case .perplexity: "Perplexity"
            case .brave: "Brave Search"
            case .ecosia: "Ecosia"
            case .startpage: "Startpage"
            case .chatGPT: "ChatGPT"
            case .custom: "Custom…"
            }
        }

        /// What a row that searches calls it.
        public var searchName: String {
            switch self {
            case .brave: name
            case .custom: "Search"
            default: "\(name) Search"
            }
        }

        /// The search address, with `%s` for what you typed. Custom's is in preferences.
        public var template: String {
            switch self {
            case .google, .custom: "https://www.google.com/search?q=%s"
            case .duckDuckGo: "https://duckduckgo.com/?q=%s"
            case .kagi: "https://kagi.com/search?q=%s"
            case .bing: "https://www.bing.com/search?q=%s"
            case .perplexity: "https://www.perplexity.ai/search?q=%s"
            case .brave: "https://search.brave.com/search?q=%s"
            case .ecosia: "https://www.ecosia.org/search?q=%s"
            case .startpage: "https://www.startpage.com/do/search?q=%s"
            case .chatGPT: "https://chatgpt.com/?q=%s"
            }
        }

        /// A search address you can use: http or https, with `%s` where the query goes.
        public static func isValidTemplate(_ template: String) -> Bool {
            let trimmed = template.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("%s"), let url = URL(string: trimmed.replacingOccurrences(of: "%s", with: "q")),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return false }
            return true
        }
    }

    /// Parts of the sidebar you can hide.
    public enum SidebarItem: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Kept so older preferences still load; the address field lives in the toolbar now.
        case addressBar
        case favorites, newTab, agentActivity, reopenTab, settings
        public var id: String { rawValue }

        /// The choices to offer.
        public static let choices: [SidebarItem] = [.favorites, .newTab, .reopenTab, .settings, .agentActivity]
        /// The ones that are rows at the foot of the sidebar.
        public static let actions: [SidebarItem] = [.reopenTab, .settings]

        /// Where it goes until you say otherwise.
        public var standardVisibility: SidebarVisibility {
            switch self {
            case .reopenTab, .settings: .hidden
            default: .always
            }
        }

        /// Agent activity only appears for a moment, so there'd be nothing to find under More.
        public var visibilityChoices: [SidebarVisibility] {
            self == .agentActivity ? [.always, .hidden] : SidebarVisibility.allCases
        }

        public var name: String {
            switch self {
            case .addressBar: "Address bar"
            case .favorites: "Favorites"
            case .newTab: "New Tab"
            case .agentActivity: "Agent activity"
            case .reopenTab: "Reopen Closed Tab"
            case .settings: "Settings"
            }
        }
    }

    /// Where a part of the sidebar goes.
    public enum SidebarVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
        case always, more, hidden
        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .always: "Always show"
            case .more: "Under More"
            case .hidden: "Don't show"
            }
        }
    }

    public enum Density: String, Codable, CaseIterable, Identifiable, Sendable {
        case compact, comfortable, roomy
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
        /// Height of a tab row.
        public var rowHeight: Double {
            switch self {
            case .compact: 30
            case .comfortable: 36
            case .roomy: 42
            }
        }
    }

    /// What a favorite looks like.
    public enum FavoriteStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A clear pane of glass.
        case glass
        /// Glass in the Space's color.
        case tinted
        /// Just the site's icon, with no tile behind it.
        case plain
        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .glass: "Glass"
            case .tinted: "Tinted"
            case .plain: "Icons only"
            }
        }
    }

    public enum FavoriteSize: String, Codable, CaseIterable, Identifiable, Sendable {
        case small, medium, large
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
    }

    /// How the Space's name shows at the top of its tabs.
    public enum SpaceHeaderStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, large, hidden
        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .standard: "Icon and name"
            case .large: "Large title"
            case .hidden: "Hidden"
            }
        }
    }

    /// How the Space switcher at the bottom of the sidebar shows.
    public enum SpaceBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case icons, dots, hidden
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
    }

    /// Where extension buttons go.
    public enum ExtensionPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Pinned extensions get their own toolbar buttons.
        case addressBar
        /// The same as `addressBar`; older builds had a separate row.
        case toolbar
        /// Only the Extensions button, which lists them all.
        case menu
        public var id: String { rawValue }

        /// The choices to offer.
        public static let choices: [ExtensionPlacement] = [.addressBar, .menu]

        public var showsButtons: Bool { self != .menu }

        public var name: String {
            switch self {
            case .addressBar, .toolbar: "Pinned extensions in the toolbar"
            case .menu: "Only in the Extensions menu"
            }
        }
    }

    private struct Stored: Codable {
        var searchEngine: SearchEngine?
        var customSearchTemplate: String?
        var godRays: Bool?
        var archiveAfterHours: Double?
        var sidebarCollapsed: Bool?
        var themeID: String?
        var customThemes: [SkyTheme]?
        var hiddenSidebarItems: Set<SidebarItem>?
        var sidebarVisibility: [String: SidebarVisibility]?
        var sceneOnNewTab: Bool?
        var density: Density?
        var favoriteStyle: FavoriteStyle?
        var favoriteSize: FavoriteSize?
        var favoritesPerRow: Int?
        var spaceHeaderStyle: SpaceHeaderStyle?
        var spaceMenuOnHover: Bool?
        var spaceBarStyle: SpaceBarStyle?
        var showsDropHints: Bool?
        var sidebarOrder: [SidebarSection]?
        var extensionPlacement: ExtensionPlacement?
        var skyBackdrop: Bool?
        var highlightFocusedPane: Bool?
        var autoPictureInPicture: Bool?
        var showMediaControls: Bool?
        var tidyInstruction: String?
        var sidebarWidth: Double?
        var shortcuts: [String: KeyBinding]?
        var newSpaceSetup: SpaceSetup?
        var finishedWelcome: Bool?
        var movedChromiumSessions: Bool?
    }

    /// A shortcut you set yourself: the key, and the modifier flags' raw value. An empty key takes
    /// the command's shortcut away.
    public struct KeyBinding: Codable, Equatable, Sendable {
        public var key: String
        public var modifiers: UInt

        public init(key: String, modifiers: UInt) {
            self.key = key
            self.modifiers = modifiers
        }

        public static let unassigned = KeyBinding(key: "", modifiers: 0)
    }

    public var searchEngine: SearchEngine = .google { didSet { save() } }
    /// The Custom engine's address, with `%s` for the query.
    public var customSearchTemplate = "" { didSet { save() } }
    /// The theme's sky behind the sidebar, instead of the system's sidebar material.
    public var skyBackdrop = true { didSet { save() } }
    /// The animated light in the sky. Off, the sky is a still gradient.
    public var godRays = true { didSet { save() } }
    /// Today tabs untouched this long are archived.
    public var archiveAfterHours: Double = 12 { didSet { save() } }
    public var sidebarCollapsed = false { didSet { save() } }
    /// The sidebar's width, as you last dragged it.
    public var sidebarWidth: Double = 240 { didSet { save() } }
    /// The app's theme; Spaces can pick their own.
    public var themeID = SkyTheme.startingID { didSet { save() } }
    public var customThemes: [SkyTheme] = [] { didSet { save() } }
    /// Parts of the sidebar hidden by older versions, until `sidebarVisibility` says otherwise.
    public var hiddenSidebarItems: Set<SidebarItem> = [] { didSet { save() } }
    /// Where you've put each part of the sidebar, by the item's raw value.
    public var sidebarVisibility: [String: SidebarVisibility] = [:] { didSet { save() } }
    /// A theme's picture fills the window for a new tab, instead of an empty page.
    public var sceneOnNewTab = true { didSet { save() } }
    public var density: Density = .comfortable { didSet { save() } }
    public var favoriteStyle: FavoriteStyle = .glass { didSet { save() } }
    public var favoriteSize: FavoriteSize = .medium { didSet { save() } }
    /// Tiles in a row of favorites; 0 fits as many as the sidebar's width allows.
    public var favoritesPerRow = 0 { didSet { save() } }
    public var spaceHeaderStyle: SpaceHeaderStyle = .standard { didSet { save() } }
    /// Keep the Space header's ··· button out of sight until the pointer is over the header.
    public var spaceMenuOnHover = false { didSet { save() } }
    public var spaceBarStyle: SpaceBarStyle = .icons { didSet { save() } }
    /// Hints like "Drag tabs here to pin them" in empty sections. Off, they show only during a drag.
    public var showsDropHints = true { didSet { save() } }
    public var sidebarOrder = SidebarSection.standardOrder { didSet { save() } }
    public var extensionPlacement: ExtensionPlacement = .addressBar { didSet { save() } }
    /// Ring the pane that has focus in a split.
    public var highlightFocusedPane = true { didSet { save() } }
    /// A playing video floats in picture in picture when you switch away from its tab.
    public var autoPictureInPicture = true { didSet { save() } }
    /// Play, pause and picture-in-picture buttons on tabs that play media.
    public var showMediaControls = true { didSet { save() } }
    /// How Tidy groups tabs ("by project", "work and personal"); empty is by topic.
    public var tidyInstruction = "" { didSet { save() } }
    /// Your own shortcuts, by menu command, over the menus' own.
    public var shortcuts: [String: KeyBinding] = [:] { didSet { save() } }
    /// The last choice in the New Space sheet.
    public var newSpaceSetup = SpaceSetup() { didSet { save() } }
    /// The welcome a new install opens with has been seen, or wasn't needed.
    public var finishedWelcome = false { didSet { save() } }
    public var movedChromiumSessions = false { didSet { save() } }

    /// Every theme you can pick: the presets, then your own.
    public var themes: [SkyTheme] { SkyTheme.presets + customThemes }

    public func theme(_ id: String?) -> SkyTheme? {
        guard let id else { return nil }
        return themes.first { $0.id == id }
    }

    /// The theme a Space shows: its own if it has one, else the app's.
    public func theme(for space: Space) -> SkyTheme {
        theme(space.themeID) ?? theme(themeID) ?? .standard
    }

    /// Whether a Space shows a theme at all: a Space's own shows even when the app has none.
    public func showsTheme(in space: Space) -> Bool { skyBackdrop || space.themeID != nil }

    public func visibility(_ item: SidebarItem) -> SidebarVisibility {
        sidebarVisibility[item.rawValue] ?? (hiddenSidebarItems.contains(item) ? .hidden : item.standardVisibility)
    }

    public func setVisibility(_ item: SidebarItem, _ visibility: SidebarVisibility) {
        sidebarVisibility[item.rawValue] = visibility
    }

    /// Always in the sidebar, rather than under More or hidden.
    public func shows(_ item: SidebarItem) -> Bool { visibility(item) == .always }

    /// What's listed under More, in the order they're offered.
    public var moreSidebarItems: [SidebarItem] { SidebarItem.choices.filter { visibility($0) == .more } }

    /// Adds or replaces a theme of your own. Presets can't be changed; saving one makes a copy.
    @discardableResult
    public func saveTheme(_ theme: SkyTheme) -> SkyTheme {
        var theme = theme
        if theme.isPreset { theme.id = UUID().uuidString }
        if let i = customThemes.firstIndex(where: { $0.id == theme.id }) {
            customThemes[i] = theme
        } else {
            customThemes.append(theme)
        }
        return theme
    }

    public func deleteTheme(_ id: String) {
        customThemes.removeAll { $0.id == id }
        if themeID == id { themeID = SkyTheme.startingID }
        pruneBackgrounds()
    }

    /// Where a theme's picture is, if it's still there.
    public func url(for image: ThemeImage) -> URL? {
        if image.builtIn { return Bundle.main.url(forResource: image.file, withExtension: nil, subdirectory: "Themes") }
        guard let url = backgroundsFolder?.appending(path: image.file),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Copies a picture into the Backgrounds folder, so a theme keeps it if the original moves.
    /// Nil if it isn't a picture Skylight can show.
    public func importBackground(from source: URL) -> ThemeImage? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        return storePicture(data, fileExtension: source.pathExtension)
    }

    private func storePicture(_ data: Data, fileExtension: String) -> ThemeImage? {
        let fileExtension = fileExtension.lowercased()
        guard let folder = backgroundsFolder, ThemeImage.fileExtensions.contains(fileExtension),
              let image = NSImage(data: data), image.isValid else { return nil }
        let file = "\(UUID().uuidString).\(fileExtension)"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: file), options: .atomic)
        } catch { return nil }
        return ThemeImage(file: file)
    }

    /// A new theme from a picture, named after the file, with colors picked to suit it.
    /// Nil if it isn't a picture Skylight can show.
    @discardableResult
    public func makeTheme(fromPicture source: URL) -> SkyTheme? {
        guard let image = importBackground(from: source) else { return nil }
        let pixels = pixels(of: url(for: image))
        let name = source.deletingPathExtension().lastPathComponent
        return saveTheme(SkyTheme(name: uniqueThemeName(name), light: .suited(to: pixels, dark: false, image: image),
                                  dark: .suited(to: pixels, dark: true, image: image), followsSpace: false))
    }

    /// Picks a look's colors again to suit its picture, keeping its picture and pattern.
    public func matchColors(of id: String, dark: Bool) {
        guard var theme = theme(id), !theme.isPreset else { return }
        let path: WritableKeyPath<SkyTheme, ThemePalette> = dark ? \.dark : \.light
        let look = theme[keyPath: path]
        guard let image = look.image else { return }
        var matched = ThemePalette.suited(to: pixels(of: url(for: image)), dark: dark, image: image)
        matched.ascii = look.ascii
        theme[keyPath: path] = matched
        saveTheme(theme)
    }

    /// Saves a theme and its pictures to one file, to keep or to share.
    public func exportTheme(_ id: String, to destination: URL) -> Bool {
        guard var theme = theme(id) else { return false }
        var pictures: [String: Data] = [:]
        for image in [theme.light.image, theme.dark.image].compactMap({ $0 }) {
            if let url = url(for: image), let data = try? Data(contentsOf: url) { pictures[image.file] = data }
        }
        // In the file, the app's own pictures are like any other.
        theme.light.image?.builtIn = false
        theme.dark.image?.builtIn = false
        guard let data = try? ThemeFile(theme: theme, pictures: pictures).encoded() else { return false }
        return (try? data.write(to: destination, options: .atomic)) != nil
    }

    /// Adds a theme from a file. A picture that's missing or isn't one leaves that look without it.
    @discardableResult
    public func importTheme(from source: URL) -> SkyTheme? {
        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ThemeFile.sizeLimit,
              let data = try? Data(contentsOf: source), let file = try? ThemeFile.decoded(from: data) else { return nil }
        var theme = file.importedTheme()
        theme.name = uniqueThemeName(theme.name)
        // Stored once each, even when both looks share a picture.
        var stored: [String: ThemeImage] = [:]
        func store(_ path: WritableKeyPath<SkyTheme, ThemePalette>) {
            guard let image = theme[keyPath: path].image else { return }
            if stored[image.file] == nil, let bytes = file.pictures[image.file] {
                stored[image.file] = storePicture(bytes, fileExtension: (image.file as NSString).pathExtension)
            }
            var kept = stored[image.file].map { new in
                var adjusted = image
                adjusted.file = new.file
                return adjusted
            }
            kept?.builtIn = false
            theme[keyPath: path].image = kept
        }
        store(\.light)
        store(\.dark)
        return saveTheme(theme)
    }

    private func uniqueThemeName(_ name: String) -> String {
        let name = name.isEmpty ? "My Theme" : name
        let taken = Set(themes.map(\.name))
        guard taken.contains(name) else { return name }
        return (2...).lazy.map { "\(name) \($0)" }.first { !taken.contains($0) } ?? name
    }

    /// A small sample of a picture's pixels, enough to judge its colors.
    private func pixels(of url: URL?) -> [RGB] {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { RGB(Double(bytes[$0]) / 255, Double(bytes[$0 + 1]) / 255, Double(bytes[$0 + 2]) / 255) }
    }

    /// Removes pictures no theme of yours uses any more.
    public func pruneBackgrounds() {
        guard let folder = backgroundsFolder,
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let used = Set(customThemes.flatMap { [$0.light.image, $0.dark.image] }.compactMap { $0?.file })
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
    }

    /// What searches go to. A custom address that isn't usable falls back to Google.
    public var searchTemplate: String {
        guard searchEngine == .custom else { return searchEngine.template }
        let custom = customSearchTemplate.trimmingCharacters(in: .whitespaces)
        return SearchEngine.isValidTemplate(custom) ? custom : SearchEngine.google.template
    }

    public var omnibox: Omnibox { Omnibox(searchTemplate: searchTemplate) }

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var backgroundsFolder: URL? {
        fileURL?.deletingLastPathComponent().appending(path: "Backgrounds")
    }
    @ObservationIgnored private var loading = false

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        loading = true
        defer { loading = false }
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        searchEngine = stored.searchEngine ?? searchEngine
        customSearchTemplate = stored.customSearchTemplate ?? customSearchTemplate
        godRays = stored.godRays ?? godRays
        archiveAfterHours = stored.archiveAfterHours ?? archiveAfterHours
        sidebarCollapsed = stored.sidebarCollapsed ?? sidebarCollapsed
        themeID = stored.themeID ?? themeID
        customThemes = stored.customThemes ?? []
        hiddenSidebarItems = stored.hiddenSidebarItems ?? []
        sidebarVisibility = stored.sidebarVisibility ?? [:]
        sceneOnNewTab = stored.sceneOnNewTab ?? sceneOnNewTab
        density = stored.density ?? density
        favoriteStyle = stored.favoriteStyle ?? favoriteStyle
        favoriteSize = stored.favoriteSize ?? favoriteSize
        favoritesPerRow = stored.favoritesPerRow ?? favoritesPerRow
        spaceHeaderStyle = stored.spaceHeaderStyle ?? spaceHeaderStyle
        spaceMenuOnHover = stored.spaceMenuOnHover ?? spaceMenuOnHover
        spaceBarStyle = stored.spaceBarStyle ?? spaceBarStyle
        showsDropHints = stored.showsDropHints ?? showsDropHints
        sidebarOrder = (stored.sidebarOrder ?? sidebarOrder).normalized
        extensionPlacement = stored.extensionPlacement ?? extensionPlacement
        skyBackdrop = stored.skyBackdrop ?? skyBackdrop
        highlightFocusedPane = stored.highlightFocusedPane ?? highlightFocusedPane
        autoPictureInPicture = stored.autoPictureInPicture ?? autoPictureInPicture
        showMediaControls = stored.showMediaControls ?? showMediaControls
        tidyInstruction = stored.tidyInstruction ?? tidyInstruction
        sidebarWidth = stored.sidebarWidth ?? sidebarWidth
        shortcuts = stored.shortcuts ?? shortcuts
        newSpaceSetup = stored.newSpaceSetup ?? newSpaceSetup
        finishedWelcome = stored.finishedWelcome ?? finishedWelcome
        movedChromiumSessions = stored.movedChromiumSessions ?? movedChromiumSessions
    }

    private func save() {
        guard !loading, let fileURL else { return }
        let stored = Stored(searchEngine: searchEngine, customSearchTemplate: customSearchTemplate, godRays: godRays,
                            archiveAfterHours: archiveAfterHours, sidebarCollapsed: sidebarCollapsed, themeID: themeID,
                            customThemes: customThemes, hiddenSidebarItems: hiddenSidebarItems, sidebarVisibility: sidebarVisibility,
                            sceneOnNewTab: sceneOnNewTab, density: density,
                            favoriteStyle: favoriteStyle, favoriteSize: favoriteSize, favoritesPerRow: favoritesPerRow,
                            spaceHeaderStyle: spaceHeaderStyle, spaceMenuOnHover: spaceMenuOnHover,
                            spaceBarStyle: spaceBarStyle, showsDropHints: showsDropHints, sidebarOrder: sidebarOrder,
                            extensionPlacement: extensionPlacement, skyBackdrop: skyBackdrop,
                            highlightFocusedPane: highlightFocusedPane, autoPictureInPicture: autoPictureInPicture,
                            showMediaControls: showMediaControls, tidyInstruction: tidyInstruction, sidebarWidth: sidebarWidth,
                            shortcuts: shortcuts, newSpaceSetup: newSpaceSetup, finishedWelcome: finishedWelcome,
                            movedChromiumSessions: movedChromiumSessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(stored).write(to: fileURL, options: .atomic)
    }
}
