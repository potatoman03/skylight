import AppKit
import Foundation
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

    public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
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
            case .newTab: "New Tab button"
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
        var appearance: Appearance?
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
    public var appearance: Appearance = .system { didSet { save(); applyAppearance() } }
    /// The theme's sky behind the sidebar, instead of the system's sidebar material.
    public var skyBackdrop = false { didSet { save() } }
    /// The animated light in the sky. Off, the sky is a still gradient.
    public var godRays = true { didSet { save() } }
    /// Today tabs untouched this long are archived.
    public var archiveAfterHours: Double = 12 { didSet { save() } }
    public var sidebarCollapsed = false { didSet { save() } }
    /// The sidebar's width, as you last dragged it.
    public var sidebarWidth: Double = 240 { didSet { save() } }
    /// The app's theme; Spaces can pick their own.
    public var themeID = SkyTheme.standard.id { didSet { save() } }
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
        if themeID == id { themeID = SkyTheme.standard.id }
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
        guard let folder = backgroundsFolder, let image = NSImage(contentsOf: source), image.isValid else { return nil }
        let file = "\(UUID().uuidString).\(source.pathExtension.lowercased())"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: folder.appending(path: file))
        } catch { return nil }
        return ThemeImage(file: file)
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
        appearance = stored.appearance ?? appearance
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
    }

    public func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func save() {
        guard !loading, let fileURL else { return }
        let stored = Stored(searchEngine: searchEngine, customSearchTemplate: customSearchTemplate, appearance: appearance, godRays: godRays,
                            archiveAfterHours: archiveAfterHours, sidebarCollapsed: sidebarCollapsed, themeID: themeID,
                            customThemes: customThemes, hiddenSidebarItems: hiddenSidebarItems, sidebarVisibility: sidebarVisibility,
                            sceneOnNewTab: sceneOnNewTab, density: density,
                            favoriteStyle: favoriteStyle, favoriteSize: favoriteSize, favoritesPerRow: favoritesPerRow,
                            spaceHeaderStyle: spaceHeaderStyle, spaceMenuOnHover: spaceMenuOnHover,
                            spaceBarStyle: spaceBarStyle, showsDropHints: showsDropHints, sidebarOrder: sidebarOrder,
                            extensionPlacement: extensionPlacement, skyBackdrop: skyBackdrop,
                            highlightFocusedPane: highlightFocusedPane, autoPictureInPicture: autoPictureInPicture,
                            showMediaControls: showMediaControls, tidyInstruction: tidyInstruction, sidebarWidth: sidebarWidth,
                            shortcuts: shortcuts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(stored).write(to: fileURL, options: .atomic)
    }
}
