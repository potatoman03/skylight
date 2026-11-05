import Foundation

/// Identifies a tab for its whole life, across launches and hibernation.
public struct TabID: Hashable, Codable, Sendable, CustomStringConvertible, CodingKeyRepresentable {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var codingKey: CodingKey { AnyKey(rawValue) }
    public init?<T: CodingKey>(codingKey: T) { rawValue = codingKey.stringValue }
    public var description: String { rawValue }
}

public struct SpaceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct ProfileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The profile every Space uses until the user makes another.
    public static let standard = ProfileID("default")
}

/// A browsing identity: one cookie jar, cache and set of site permissions. Spaces share profiles,
/// so you sign in once and stay signed in across the Spaces that use the same profile.
public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public let id: ProfileID
    public var name: String
    /// An emoji or SF Symbol name for the profile's badge; nil shows its initial.
    public var icon: String?
    /// 0...1, the badge's color; nil is neutral.
    public var hue: Double?
    /// The profile whose saved passwords this one uses instead of its own; nil keeps its own.
    public var passwordsFrom: ProfileID?

    public init(id: ProfileID = ProfileID(), name: String, icon: String? = nil, hue: Double? = nil,
                passwordsFrom: ProfileID? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.hue = hue
        self.passwordsFrom = passwordsFrom
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A tab as the user knows it. Whether a live web page backs it is runtime state,
/// tracked separately in `PageStatus`.
public struct Tab: Identifiable, Codable, Equatable, Sendable {
    public let id: TabID
    public var url: URL
    public var title: String
    /// A name you gave the tab, shown instead of the page's title.
    public var customTitle: String?
    public var faviconURL: URL?
    public var createdAt: Date
    public var lastActiveAt: Date

    public init(id: TabID = TabID(), url: URL, title: String = "", faviconURL: URL? = nil, now: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.createdAt = now
        self.lastActiveAt = now
    }

    /// The title to show, falling back to the host while a page has none yet.
    public var displayTitle: String {
        if let customTitle { return customTitle }
        if !title.isEmpty { return title }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    /// The title without the site's name around it, for the sidebar, where the favicon already says
    /// which site it is: "Page not found · GitHub · GitHub" is "Page not found".
    public var shortTitle: String {
        guard customTitle == nil, !title.isEmpty else { return displayTitle }
        let labels = Self.siteLabels(url)
        guard !labels.isEmpty else { return title }
        func isSite(_ part: Substring) -> Bool {
            let word = part.lowercased().filter { $0.isLetter || $0.isNumber }
            return word.count >= 3 && labels.contains { word.contains($0) || $0.contains(word) }
        }
        var rest = Substring(title)
        // The site's name tacked on the end, often more than once.
        for _ in 0..<3 {
            guard let cut = Self.separators.compactMap({ rest.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound }),
                  isSite(rest[cut.upperBound...]), !rest[..<cut.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty else { break }
            rest = rest[..<cut.lowerBound]
        }
        // Or at the start: "GitHub - owner/repo". A home page's title describes the site, so it stays.
        if url.path.count > 1, let cut = Self.separators.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
           isSite(rest[..<cut.lowerBound]), !rest[cut.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
            rest = rest[cut.upperBound...]
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static let separators = [" · ", " - ", " | ", " — ", " – ", " • "]

    /// The words of a host that name the site: mail.google.com → ["mail", "google"].
    private static func siteLabels(_ url: URL) -> [String] {
        guard var parts = url.host(percentEncoded: false)?.lowercased().split(separator: "."), parts.count > 1 else { return [] }
        parts.removeLast()
        return parts.map(String.init).filter { $0.count >= 3 && $0 != "www" }
    }
}

/// A named group of a Space's pinned tabs, which you can open and close in the sidebar.
public struct TabFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    /// In the folder's own order. Every one is also in the Space's `pinned`.
    public var tabs: [TabID]
    public var isOpen: Bool

    public init(id: String = UUID().uuidString, name: String, tabs: [TabID] = [], isOpen: Bool = true) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.isOpen = isOpen
    }
}

public enum TabSection: String, Codable, Sendable, CaseIterable {
    /// Kept until the user unpins them.
    case pinned
    /// Everyday tabs, archived automatically when idle.
    case today
}

/// A Space: its own tabs, color and icon, browsing as one profile.
/// How strongly a Space's color washes through the sidebar.
public enum SpaceTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, subtle, strong

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

public struct Space: Identifiable, Codable, Equatable, Sendable {
    public let id: SpaceID
    public var name: String
    /// 0...1, the hue of the Space's sky.
    public var hue: Double
    /// An emoji or SF Symbol name; nil shows the Space's color.
    public var icon: String?
    public var profileID: ProfileID
    /// A theme just for this Space; nil uses the app's theme.
    public var themeID: String?
    /// How strongly the Space's color washes through the sidebar.
    public var tint: SpaceTint
    public var pinned: [TabID]
    public var today: [TabID]
    public var selectedTabID: TabID?
    /// Tabs shown together. Each split's tabs sit in one section.
    public var splits: [TabSplit]
    /// Folders of pinned tabs, shown above the loose ones. Their tabs stay in `pinned`.
    public var folders: [TabFolder]

    public init(id: SpaceID = SpaceID(), name: String, hue: Double, icon: String? = nil, profileID: ProfileID = .standard,
                themeID: String? = nil, tint: SpaceTint = .none, pinned: [TabID] = [], today: [TabID] = [],
                selectedTabID: TabID? = nil, splits: [TabSplit] = [], folders: [TabFolder] = []) {
        self.id = id
        self.name = name
        self.hue = hue
        self.icon = icon
        self.profileID = profileID
        self.themeID = themeID
        self.tint = tint
        self.pinned = pinned
        self.today = today
        self.selectedTabID = selectedTabID
        self.splits = splits
        self.folders = folders
    }

    enum CodingKeys: String, CodingKey { case id, name, hue, icon, profileID, themeID, tint, pinned, today, selectedTabID, splits, folders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SpaceID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hue = try c.decode(Double.self, forKey: .hue)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        profileID = try c.decodeIfPresent(ProfileID.self, forKey: .profileID) ?? .standard
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID)
        // A tint from a newer build shouldn't cost you your Spaces.
        tint = (try? c.decodeIfPresent(SpaceTint.self, forKey: .tint)) ?? .none
        pinned = try c.decodeIfPresent([TabID].self, forKey: .pinned) ?? []
        today = try c.decodeIfPresent([TabID].self, forKey: .today) ?? []
        selectedTabID = try c.decodeIfPresent(TabID.self, forKey: .selectedTabID)
        splits = try c.decodeIfPresent([TabSplit].self, forKey: .splits) ?? []
        folders = try c.decodeIfPresent([TabFolder].self, forKey: .folders) ?? []
    }

    public var allTabIDs: [TabID] { pinned + today }

    public func contains(_ id: TabID) -> Bool { pinned.contains(id) || today.contains(id) }

    public func section(of id: TabID) -> TabSection? {
        if pinned.contains(id) { return .pinned }
        if today.contains(id) { return .today }
        return nil
    }

    /// The folder a tab is in, if any.
    public func folder(containing id: TabID) -> TabFolder? { folders.first { $0.tabs.contains(id) } }

    /// Pinned tabs that aren't in a folder, in order.
    public var loosePinned: [TabID] {
        guard !folders.isEmpty else { return pinned }
        let foldered = Set(folders.flatMap(\.tabs))
        return pinned.filter { !foldered.contains($0) }
    }

    public subscript(section: TabSection) -> [TabID] {
        get { section == .pinned ? pinned : today }
        set { if section == .pinned { pinned = newValue } else { today = newValue } }
    }
}

/// Enough to undo a close: the tab and where it lived.
public struct ClosedTab: Codable, Equatable, Sendable {
    public var tab: Tab
    public var spaceID: SpaceID
    public var section: TabSection
    public var index: Int
}

/// Live, non-persisted facts about a tab's page, reported by the engine.
public struct PageStatus: Equatable, Sendable {
    public var isAwake = false
    public var isLoading = false
    public var progress: Double = 0
    public var canGoBack = false
    public var canGoForward = false

    public init() {}
}

/// What the engine reports when a page changes.
extension URL {
    /// Skylight's own pages (`skylight://settings`) are drawn natively, not by the engine.
    public var isSkylightPage: Bool { scheme == "skylight" }
}

public struct PageMetadata: Equatable, Sendable {
    public var url: URL?
    public var title: String?
    public var faviconURL: URL?

    public init(url: URL? = nil, title: String? = nil, faviconURL: URL? = nil) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
    }
}
