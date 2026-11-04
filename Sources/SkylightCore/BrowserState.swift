import Foundation

/// The persisted shape of the browser: profiles, Spaces, favorites, tabs and selection.
/// A value type, so every change goes through `BrowserReducer` and is easy to test.
public struct BrowserState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let closedTabLimit = 25

    public var version = BrowserState.schemaVersion
    public var profiles: [Profile]
    public var spaces: [Space]
    /// Favorites sit above every Space, shared by all of them.
    public var favorites: [TabID] = []
    public var tabs: [TabID: Tab]
    public var activeSpaceID: SpaceID
    public var closedTabs: [ClosedTab] = []

    public init(profiles: [Profile] = [Profile(id: .standard, name: "Default")], spaces: [Space],
                favorites: [TabID] = [], tabs: [TabID: Tab] = [:], activeSpaceID: SpaceID) {
        precondition(spaces.contains { $0.id == activeSpaceID }, "active Space must exist")
        self.profiles = profiles
        self.spaces = spaces
        self.favorites = favorites
        self.tabs = tabs
        self.activeSpaceID = activeSpaceID
    }

    /// A first-launch state: two Spaces on one profile, nothing open.
    public static func initial() -> BrowserState {
        let personal = Space(name: "Personal", hue: 0.58, icon: "sun.max")
        let work = Space(name: "Work", hue: 0.08, icon: "briefcase")
        return BrowserState(spaces: [personal, work], activeSpaceID: personal.id)
    }

    enum CodingKeys: String, CodingKey { case version, profiles, spaces, favorites, tabs, activeSpaceID, closedTabs }

    /// Fields added after version 1 are optional, so older files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.schemaVersion
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? [Profile(id: .standard, name: "Default")]
        spaces = try c.decode([Space].self, forKey: .spaces)
        favorites = try c.decodeIfPresent([TabID].self, forKey: .favorites) ?? []
        tabs = try c.decodeIfPresent([TabID: Tab].self, forKey: .tabs) ?? [:]
        activeSpaceID = try c.decode(SpaceID.self, forKey: .activeSpaceID)
        closedTabs = try c.decodeIfPresent([ClosedTab].self, forKey: .closedTabs) ?? []
    }

    // MARK: - Lookup

    public var activeSpaceIndex: Int { spaces.firstIndex { $0.id == activeSpaceID } ?? 0 }
    public var activeSpace: Space { spaces[activeSpaceIndex] }

    public var selectedTabID: TabID? { activeSpace.selectedTabID }
    public var selectedTab: Tab? { selectedTabID.flatMap { tabs[$0] } }

    public func spaceIndex(containing id: TabID) -> Int? { spaces.firstIndex { $0.contains(id) } }

    public func space(containing id: TabID) -> Space? { spaceIndex(containing: id).map { spaces[$0] } }

    public func tabs(in space: Space, _ section: TabSection) -> [Tab] { space[section].compactMap { tabs[$0] } }

    public var favoriteTabs: [Tab] { favorites.compactMap { tabs[$0] } }

    public func isFavorite(_ id: TabID) -> Bool { favorites.contains(id) }

    /// The profile a tab's page loads in. Favorites use the active Space's profile.
    public func profileID(forTab id: TabID) -> ProfileID {
        (space(containing: id) ?? activeSpace).profileID
    }

    public func profile(_ id: ProfileID) -> Profile? { profiles.first { $0.id == id } }

    /// Every tab that should stay alive because the user is looking at it in some Space.
    public var selectedTabIDs: Set<TabID> { Set(spaces.compactMap(\.selectedTabID)) }

    /// Repairs references that can drift after a crash or a hand-edited file.
    public mutating func normalize() {
        if spaces.isEmpty { self = .initial(); return }
        if !spaces.contains(where: { $0.id == activeSpaceID }) { activeSpaceID = spaces[0].id }
        if !profiles.contains(where: { $0.id == .standard }) { profiles.insert(Profile(id: .standard, name: "Default"), at: 0) }
        var seen = Set<TabID>()
        favorites = favorites.filter { tabs[$0] != nil && seen.insert($0).inserted }
        let profileIDs = Set(profiles.map(\.id))
        for i in spaces.indices {
            if !profileIDs.contains(spaces[i].profileID) { spaces[i].profileID = .standard }
            for section in TabSection.allCases {
                spaces[i][section] = spaces[i][section].filter { tabs[$0] != nil && seen.insert($0).inserted }
            }
            if let sel = spaces[i].selectedTabID, !spaces[i].contains(sel), !favorites.contains(sel) { spaces[i].selectedTabID = nil }
        }
        tabs = tabs.filter { seen.contains($0.key) }
    }
}
