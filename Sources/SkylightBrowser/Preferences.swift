import AppKit
import Foundation
import Observation
import SkylightCore

/// Settings that aren't browser state. Saved to `preferences.json` on every change.
@MainActor
@Observable
public final class Preferences {
    public enum SearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
        case google, duckDuckGo, kagi, bing, perplexity

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .google: "Google"
            case .duckDuckGo: "DuckDuckGo"
            case .kagi: "Kagi"
            case .bing: "Bing"
            case .perplexity: "Perplexity"
            }
        }

        public var template: String {
            switch self {
            case .google: "https://www.google.com/search?q=%s"
            case .duckDuckGo: "https://duckduckgo.com/?q=%s"
            case .kagi: "https://kagi.com/search?q=%s"
            case .bing: "https://www.bing.com/search?q=%s"
            case .perplexity: "https://www.perplexity.ai/search?q=%s"
            }
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
        case favorites, newTab, agentActivity
        public var id: String { rawValue }

        /// The choices to offer.
        public static let choices: [SidebarItem] = [.favorites, .newTab, .agentActivity]

        public var name: String {
            switch self {
            case .addressBar: "Address bar"
            case .favorites: "Favorites"
            case .newTab: "New Tab button"
            case .agentActivity: "Agent activity"
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
        var appearance: Appearance?
        var godRays: Bool?
        var archiveAfterHours: Double?
        var sidebarCollapsed: Bool?
        var themeID: String?
        var customThemes: [SkyTheme]?
        var hiddenSidebarItems: Set<SidebarItem>?
        var density: Density?
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
    public var hiddenSidebarItems: Set<SidebarItem> = [] { didSet { save() } }
    public var density: Density = .comfortable { didSet { save() } }
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

    public func shows(_ item: SidebarItem) -> Bool { !hiddenSidebarItems.contains(item) }

    public func setShows(_ item: SidebarItem, _ shown: Bool) {
        if shown { hiddenSidebarItems.remove(item) } else { hiddenSidebarItems.insert(item) }
    }

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
    }

    public var omnibox: Omnibox { Omnibox(searchTemplate: searchEngine.template) }

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var loading = false

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        loading = true
        defer { loading = false }
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        searchEngine = stored.searchEngine ?? searchEngine
        appearance = stored.appearance ?? appearance
        godRays = stored.godRays ?? godRays
        archiveAfterHours = stored.archiveAfterHours ?? archiveAfterHours
        sidebarCollapsed = stored.sidebarCollapsed ?? sidebarCollapsed
        themeID = stored.themeID ?? themeID
        customThemes = stored.customThemes ?? []
        hiddenSidebarItems = stored.hiddenSidebarItems ?? []
        density = stored.density ?? density
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
        let stored = Stored(searchEngine: searchEngine, appearance: appearance, godRays: godRays,
                            archiveAfterHours: archiveAfterHours, sidebarCollapsed: sidebarCollapsed, themeID: themeID,
                            customThemes: customThemes, hiddenSidebarItems: hiddenSidebarItems, density: density,
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
