import Foundation

/// Every change to the browser, whoever asks for it: a click, a shortcut, a package or an agent.
public enum BrowserAction: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
        /// Right below the selected tab in Today (or at the top when a pinned tab is selected).
        case afterSelected
        case top
        case end
    }

    case openTab(URL, placement: Placement = .afterSelected, select: Bool = true, space: SpaceID? = nil)
    case closeTab(TabID)
    case reopenClosedTab
    case selectTab(TabID)
    case selectAdjacentTab(offset: Int)
    case navigate(TabID, URL)
    case goBack(TabID)
    case goForward(TabID)
    case reload(TabID)
    case stop(TabID)
    case togglePin(TabID)
    case moveTab(TabID, to: TabSection, index: Int)
    case moveTabToSpace(TabID, SpaceID)

    case createSpace(name: String, hue: Double? = nil)
    case renameSpace(SpaceID, String)
    case deleteSpace(SpaceID)
    case switchSpace(SpaceID)
    case switchSpaceByOffset(Int)

    /// The engine reports a new URL, title or icon for a tab's page.
    case pageDidUpdate(TabID, PageMetadata)
    /// Close Today tabs nobody has looked at since `cutoff` (Arc-style auto-archive).
    case archiveTabs(idleSince: Date)
}

/// What the engine must do as a result of an action. The reducer never touches the engine.
public enum BrowserEffect: Equatable, Sendable {
    /// The visible tab changed (nil: no tab, show the start state).
    case showTab(TabID?)
    case load(TabID, URL)
    case goBack(TabID)
    case goForward(TabID)
    case reload(TabID)
    case stop(TabID)
    /// Tear down the tab's page, if it has one.
    case discardPage(TabID)
    /// A Space was deleted: release its engine profile.
    case releaseSpace(SpaceID)
}

public struct ReduceResult: Equatable, Sendable {
    public var effects: [BrowserEffect] = []
    /// Set by `.openTab`, so callers (agents, packages) can refer to the new tab.
    public var openedTabID: TabID?
    /// False when the action referred to something that doesn't exist.
    public var applied = true

    public init(effects: [BrowserEffect] = [], openedTabID: TabID? = nil, applied: Bool = true) {
        self.effects = effects
        self.openedTabID = openedTabID
        self.applied = applied
    }

    static let ignored = ReduceResult(applied: false)
}
