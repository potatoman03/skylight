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

    public init(id: ProfileID = ProfileID(), name: String) {
        self.id = id
        self.name = name
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
        if !title.isEmpty { return title }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }
}

public enum TabSection: String, Codable, Sendable, CaseIterable {
    /// Kept until the user unpins them.
    case pinned
    /// Everyday tabs, archived automatically when idle.
    case today
}

/// A Space: its own tabs, color and icon, browsing as one profile.
public struct Space: Identifiable, Codable, Equatable, Sendable {
    public let id: SpaceID
    public var name: String
    /// 0...1, the hue of the Space's sky.
    public var hue: Double
    /// An emoji or SF Symbol name; nil shows the Space's color.
    public var icon: String?
    public var profileID: ProfileID
    public var pinned: [TabID]
    public var today: [TabID]
    public var selectedTabID: TabID?

    public init(id: SpaceID = SpaceID(), name: String, hue: Double, icon: String? = nil, profileID: ProfileID = .standard,
                pinned: [TabID] = [], today: [TabID] = [], selectedTabID: TabID? = nil) {
        self.id = id
        self.name = name
        self.hue = hue
        self.icon = icon
        self.profileID = profileID
        self.pinned = pinned
        self.today = today
        self.selectedTabID = selectedTabID
    }

    enum CodingKeys: String, CodingKey { case id, name, hue, icon, profileID, pinned, today, selectedTabID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SpaceID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hue = try c.decode(Double.self, forKey: .hue)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        profileID = try c.decodeIfPresent(ProfileID.self, forKey: .profileID) ?? .standard
        pinned = try c.decodeIfPresent([TabID].self, forKey: .pinned) ?? []
        today = try c.decodeIfPresent([TabID].self, forKey: .today) ?? []
        selectedTabID = try c.decodeIfPresent(TabID.self, forKey: .selectedTabID)
    }

    public var allTabIDs: [TabID] { pinned + today }

    public func contains(_ id: TabID) -> Bool { pinned.contains(id) || today.contains(id) }

    public func section(of id: TabID) -> TabSection? {
        if pinned.contains(id) { return .pinned }
        if today.contains(id) { return .today }
        return nil
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
