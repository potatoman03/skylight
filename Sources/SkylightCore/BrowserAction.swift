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
    /// Closes any tab for good, pinned and favorites included. (`closeTab` only unloads those.)
    case removeTab(TabID)
    /// Moves a tab into the favorites above every Space, or back out into the active Space.
    case toggleFavorite(TabID)
    /// Closes every Today tab in the active Space except the selected one.
    case clearToday
    case moveTab(TabID, to: TabSection, index: Int)
    case moveTabToSpace(TabID, SpaceID)
    /// Puts a tab in the favorites at `index` (or moves it there within them).
    case moveToFavorites(TabID, index: Int)
    /// Names a tab yourself; an empty name goes back to the page's title.
    case renameTab(TabID, String)

    /// A new folder in a Space's pinned tabs, holding `tabs` (which get pinned if they aren't).
    case createFolder(id: String, space: SpaceID, name: String, tabs: [TabID] = [])
    case renameFolder(String, String)
    /// Removes a folder. Its tabs stay pinned, or close with it when `closeTabs` is set.
    case deleteFolder(String, closeTabs: Bool = false)
    case setFolderOpen(String, Bool)
    /// Moves a folder to another position among the Space's folders.
    case moveFolder(String, to: Int)
    /// Puts a tab in a folder at `index` (pinning it, in the folder's Space), or with nil takes it
    /// out of its folder and leaves it pinned.
    case moveTabToFolder(TabID, folder: String?, index: Int = .max)

    /// Puts `tab` beside `target`'s pane, making a split if there isn't one.
    case splitTab(TabID, beside: TabID, edge: SplitEdge)
    /// Takes a tab out of its split. A split with one pane left goes away.
    case leaveSplit(TabID)
    /// Undoes the split the tab is in.
    case dissolveSplit(TabID)
    /// New pane sizes for the split the tab is in.
    case resizeSplit(TabID, fractions: [Double])
    /// Side by side becomes stacked, and back.
    case rotateSplit(TabID)
    /// Moves a pane to another position in its split.
    case movePane(TabID, to: Int)

    /// A new Space uses `profile`, or the active Space's, so its logins, passwords and extensions
    /// carry over.
    case createSpace(name: String, hue: Double? = nil, profile: ProfileID? = nil)
    /// A new empty Space that looks like this one and shares its profile.
    case duplicateSpace(SpaceID)
    case renameSpace(SpaceID, String)
    case deleteSpace(SpaceID)
    case switchSpace(SpaceID)
    case switchSpaceByOffset(Int)
    case setSpaceHue(SpaceID, Double)
    case setSpaceIcon(SpaceID, String?)
    /// nil goes back to the app's theme.
    case setSpaceTheme(SpaceID, String?)
    case setSpaceTint(SpaceID, SpaceTint)
    /// Changing a Space's profile reloads its pages in the new cookie jar.
    case assignProfile(SpaceID, ProfileID)

    /// With `passwordsFrom`, the new profile uses that profile's saved passwords.
    case createProfile(name: String, passwordsFrom: ProfileID? = nil)
    case renameProfile(ProfileID, String)
    case setProfileIcon(ProfileID, String?)
    case setProfileHue(ProfileID, Double?)
    /// Spaces on the deleted profile move to the default one.
    case deleteProfile(ProfileID)

    /// Adds Spaces, pinned tabs and favorites brought over from another browser.
    case importBrowserData(BrowserImport)

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
    /// A profile was deleted: release its engine resources.
    case releaseProfile(ProfileID)
}

/// Bookmarks and Spaces read from another browser (Arc, Chrome).
public struct BrowserImport: Equatable, Sendable {
    public struct Link: Equatable, Sendable {
        public var url: URL
        public var title: String
        public init(url: URL, title: String) { self.url = url; self.title = title }
    }

    public struct ImportedSpace: Equatable, Sendable {
        public var name: String
        public var icon: String?
        public var hue: Double?
        public var pinned: [Link]
        public init(name: String, icon: String? = nil, hue: Double? = nil, pinned: [Link]) {
            self.name = name
            self.icon = icon
            self.hue = hue
            self.pinned = pinned
        }
    }

    public var source: String
    public var spaces: [ImportedSpace]
    public var favorites: [Link]

    public init(source: String, spaces: [ImportedSpace], favorites: [Link]) {
        self.source = source
        self.spaces = spaces
        self.favorites = favorites
    }

    public var isEmpty: Bool { favorites.isEmpty && spaces.allSatisfy(\.pinned.isEmpty) }
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
