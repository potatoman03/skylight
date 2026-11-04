import Foundation

/// The persisted shape of the browser: Spaces, tabs and selection.
/// A value type, so every change goes through `BrowserReducer` and is easy to test.
public struct BrowserState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let closedTabLimit = 25

    public var version = BrowserState.schemaVersion
    public var spaces: [Space]
    public var tabs: [TabID: Tab]
    public var activeSpaceID: SpaceID
    public var closedTabs: [ClosedTab] = []

    public init(spaces: [Space], tabs: [TabID: Tab] = [:], activeSpaceID: SpaceID) {
        precondition(spaces.contains { $0.id == activeSpaceID }, "active Space must exist")
        self.spaces = spaces
        self.tabs = tabs
        self.activeSpaceID = activeSpaceID
    }

    /// A first-launch state: two Spaces, nothing open.
    public static func initial() -> BrowserState {
        let personal = Space(name: "Personal", hue: 0.09)
        let work = Space(name: "Work", hue: 0.52)
        return BrowserState(spaces: [personal, work], activeSpaceID: personal.id)
    }

    // MARK: - Lookup

    public var activeSpaceIndex: Int { spaces.firstIndex { $0.id == activeSpaceID } ?? 0 }
    public var activeSpace: Space { spaces[activeSpaceIndex] }

    public var selectedTabID: TabID? { activeSpace.selectedTabID }
    public var selectedTab: Tab? { selectedTabID.flatMap { tabs[$0] } }

    public func spaceIndex(containing id: TabID) -> Int? { spaces.firstIndex { $0.contains(id) } }

    public func space(containing id: TabID) -> Space? { spaceIndex(containing: id).map { spaces[$0] } }

    public func tabs(in space: Space, _ section: TabSection) -> [Tab] { space[section].compactMap { tabs[$0] } }

    /// Every tab that should stay alive because the user is looking at it in some Space.
    public var selectedTabIDs: Set<TabID> { Set(spaces.compactMap(\.selectedTabID)) }

    /// Repairs references that can drift after a crash or a hand-edited file.
    public mutating func normalize() {
        if spaces.isEmpty { self = .initial(); return }
        if !spaces.contains(where: { $0.id == activeSpaceID }) { activeSpaceID = spaces[0].id }
        var seen = Set<TabID>()
        for i in spaces.indices {
            for section in TabSection.allCases {
                spaces[i][section] = spaces[i][section].filter { tabs[$0] != nil && seen.insert($0).inserted }
            }
            if let sel = spaces[i].selectedTabID, !spaces[i].contains(sel) { spaces[i].selectedTabID = nil }
        }
        tabs = tabs.filter { seen.contains($0.key) }
    }
}
