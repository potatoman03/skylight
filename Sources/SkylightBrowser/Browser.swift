import AppKit
import Observation
import SkylightAgent
import SkylightCore
import SkylightEngine
import SkylightKit
import SkylightMCP

/// The composition root: owns every service and connects them. The UI talks to this object.
@MainActor
@Observable
public final class Browser {
    public let store: BrowserStore
    public let pages: PageCoordinator
    public let prompts = PromptCenter()
    public let toasts = ToastCenter()
    public let packages: PackageService
    public let agents: AgentService
    public let commandBar = CommandBarModel()
    public let preferences: Preferences
    public let passwords: PasswordService
    public private(set) var mcpConnection: MCPConnection?
    /// The Space being renamed, if the rename alert is up.
    public var renameSpace: SpaceID?

    public var omnibox: Omnibox { preferences.omnibox }
    @ObservationIgnored private let engine: WebEngine
    @ObservationIgnored private let mcp: MCPServer

    public init(engine: WebEngine, paths: AppPaths, version: String, credentials: CredentialStore) {
        self.engine = engine
        let preferences = Preferences(fileURL: paths.preferencesFile)
        self.preferences = preferences
        self.passwords = PasswordService(store: credentials, toasts: toasts,
                                         neverFile: paths.root.appending(path: "password-exceptions.json"))
        let store = BrowserStore(persistence: JSONFileStateStore(fileURL: paths.stateFile))
        self.store = store
        self.pages = PageCoordinator(engine: engine, paths: paths, store: store)
        self.packages = PackageService(directory: paths.packagesDirectory)
        self.agents = AgentService(store: store, pages: pages, packages: packages, omnibox: { preferences.omnibox }, approvals: prompts)
        self.mcp = MCPServer(
            catalog: agents.hub,
            info: .init(name: "skylight", version: version, instructions: Self.agentInstructions),
            connectionFile: paths.mcpConnectionFile)

        pages.archiveAfter = { preferences.archiveAfterHours * 60 * 60 }
        store.effectHandler = pages
        pages.sink = self
        pages.onPageGone = { [weak self] id, tabClosed in
            self?.agents.forgetTab(id)
            self?.passwords.pageWentAway(id)
            if tabClosed { self?.prompts.dismissAll(for: id) }
        }
        commandBar.source = self
        packages.onScriptsChange = { [weak self] _ in self?.updatePageScripts() }
        packages.evaluateEverywhere = { [weak self] script in
            for page in self?.pages.awakePages ?? [] { Task { _ = try? await page.evaluate(script) } }
        }
    }

    public func start() {
        preferences.applyAppearance()
        packages.start()
        updatePageScripts()
        pages.start()
        mcp.start { [weak self] connection in self?.mcpConnection = connection }
    }

    /// Closes every page, saves, then calls `completion` once the engine may shut down.
    public func shutdown(completion: @escaping @MainActor () -> Void) {
        store.flush()
        mcp.stop()
        pages.closeAll(completion: completion)
    }

    private func updatePageScripts() {
        engine.setPageScripts(AgentService.pageScripts + [PasswordService.pageScript] + packages.scripts)
    }

    static let agentInstructions = """
    Skylight is the user's web browser. Use list_tabs to see what's open and read_page to read a tab \
    (text plus interactive elements with refs). Act with click, type_text, navigate and open_tab. \
    Actions that change things ask the user first. Some sites offer their own tools through WebMCP: \
    they appear as site_<host>__<tool> for the selected tab, or call them with call_site_tool.
    """

    // MARK: - Actions the UI uses

    /// Opens what the user typed: a URL or a search.
    public func open(_ input: String, inNewTab: Bool) {
        guard let url = omnibox.interpret(input)?.url else { return }
        if !inNewTab, let id = store.state.selectedTabID {
            store.send(.navigate(id, url))
        } else {
            store.send(.openTab(url))
        }
    }

    public var selectedStatus: PageStatus {
        store.state.selectedTabID.map(store.status(of:)) ?? PageStatus()
    }

    public func copyMCPCommand() {
        guard let command = mcpConnection?.claudeCommand else {
            return toasts.show("The agent server isn't running", symbol: "exclamationmark.triangle")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        toasts.show("Copied the Claude Code command", symbol: "doc.on.clipboard")
    }

    public func createBoostForCurrentSite() {
        guard let host = store.state.selectedTab?.url.host(), !host.isEmpty else {
            return toasts.show("Open a website first", symbol: "exclamationmark.triangle")
        }
        do {
            try packages.createBoost(for: host)
            toasts.show("Created a boost for \(host)", symbol: "paintbrush")
        } catch {
            toasts.show("Couldn't create the boost: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    public func runPackageCommand(packageID: String, commandID: String, title: String) {
        guard let id = store.state.selectedTabID, let page = pages.wake(id) else { return }
        Task { [toasts] in
            do {
                _ = try await page.evaluate(PackageScripts.runCommand(packageID: packageID, commandID: commandID))
            } catch {
                toasts.show("\(title) failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Types a saved login into the selected tab.
    public func fillLogin(_ credential: Credential) {
        guard let id = store.state.selectedTabID, let page = pages.page(for: id) ?? pages.wake(id) else { return }
        passwords.fill(credential, in: page, url: store.state.tabs[id]?.url)
    }

    public enum ImportSource: String, CaseIterable, Sendable {
        case arc = "Arc", aside = "Aside", chrome = "Chrome", dia = "Dia", brave = "Brave", edge = "Edge", vivaldi = "Vivaldi"

        /// Where the browser keeps what we import: Arc's sidebar, or a Chromium `Bookmarks` file.
        public var file: URL {
            let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
            return switch self {
            case .arc: BrowserImporters.arcFile
            case .aside: support.appending(path: "Aside/Default/Bookmarks")
            case .chrome: support.appending(path: "Google/Chrome/Default/Bookmarks")
            case .dia: support.appending(path: "Dia/User Data/Default/Bookmarks")
            case .brave: support.appending(path: "BraveSoftware/Brave-Browser/Default/Bookmarks")
            case .edge: support.appending(path: "Microsoft Edge/Default/Bookmarks")
            case .vivaldi: support.appending(path: "Vivaldi/Default/Bookmarks")
            }
        }

        public var isAvailable: Bool { FileManager.default.fileExists(atPath: file.path) }

        /// What comes over, for the import screen.
        public var summary: String {
            switch self {
            case .arc: "Spaces, pinned tabs and favorites"
            case .aside: "Sidebar folders as Spaces, plus bookmarks"
            default: "Bookmarks bar as favorites, folders as Spaces"
            }
        }
    }

    /// Brings Spaces, pinned tabs and favorites over from another browser. Returns a summary.
    @discardableResult
    public func importBrowser(_ source: ImportSource) -> String {
        do {
            let data = try Data(contentsOf: source.file)
            let imported = source == .arc ? try BrowserImporters.arc(data)
                : try BrowserImporters.chromium(data, browser: source.rawValue)
            let before = store.state.tabs.count
            store.send(.importBrowserData(imported))
            let added = store.state.tabs.count - before
            let message = added == 0 ? "Everything from \(source.rawValue) is already here"
                : "Imported \(added) tab\(added == 1 ? "" : "s") from \(source.rawValue)"
            toasts.show(message, symbol: "square.and.arrow.down")
            return message
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't import from \(source.rawValue)."
            toasts.show(message, symbol: "exclamationmark.triangle")
            return message
        }
    }

    public static let settingsURL = URL(string: "skylight://settings")!

    /// Shows the settings page: the open one if there is one, else a new tab.
    public func openSettings(_ section: String? = nil) {
        let url = section.map { Self.settingsURL.appending(path: $0) } ?? Self.settingsURL
        let state = store.state
        if let id = (state.favorites + state.activeSpace.allTabIDs).first(where: { state.tabs[$0]?.url.isSkylightPage == true }) {
            store.send(.selectTab(id))
            if section != nil { store.send(.pageDidUpdate(id, PageMetadata(url: url))) }
        } else if let id = store.send(.openTab(url)).openedTabID {
            store.send(.pageDidUpdate(id, PageMetadata(title: "Settings")))
        }
    }

    public func toggleSidebar() {
        preferences.sidebarCollapsed.toggle()
    }

    public func showDeveloperTools() {
        guard let id = store.state.selectedTabID else { return }
        pages.wake(id)?.showDeveloperTools()
    }
}

// MARK: - Page events

extension Browser: PageEventSink {
    public func tab(_ id: TabID, didReceive message: JSONValue) async throws -> JSONValue {
        switch message["type"]?.stringValue {
        case WebMCP.toolsMessageType:
            agents.updateSiteTools(WebMCP.parseTools(message), tab: id)
            return .null
        case let type? where type.hasPrefix("passwords."):
            return passwords.handle(message, tab: id, url: store.state.tabs[id]?.url)
        default:
            throw WebEngineError.script("Unknown message.")
        }
    }

    public func tab(_ id: TabID, requestsPermission request: PermissionRequest) {
        prompts.enqueue(request, tab: id)
    }

    public func tab(_ id: TabID, requestsDialog request: DialogRequest) {
        prompts.enqueue(request, tab: id)
    }

    public func tab(_ id: TabID, didFinishDownload fileURL: URL) {
        toasts.show("Downloaded \(fileURL.lastPathComponent)", symbol: "arrow.down.circle",
                    action: ("Show", { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }))
    }
}

// MARK: - Command bar rows

extension Browser: CommandSource {
    public func commandItems(for raw: String, mode: CommandBarModel.Mode) -> [CommandItem] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [CommandItem] = []
        let newTab = mode == .newTab

        if let interpretation = omnibox.interpret(query) {
            switch interpretation {
            case let .address(url):
                rows.append(CommandItem(id: "open", kind: .address, title: url.absoluteString,
                                        subtitle: newTab ? "Open in a new tab" : "Go", symbol: "arrow.up.right", pageURL: url) { [weak self] in
                    self?.open(query, inNewTab: newTab)
                })
            case let .search(text, _):
                rows.append(CommandItem(id: "search", kind: .search, title: text, subtitle: "Search", symbol: "magnifyingglass") { [weak self] in
                    self?.open(query, inNewTab: newTab)
                })
            }
        }

        // Open tabs, any Space.
        let state = store.state
        var tabRows: [(Int, CommandItem)] = []
        let favoritesSpace = Space(id: state.activeSpaceID, name: "Favorites", hue: 0, today: state.favorites)
        for space in [favoritesSpace] + state.spaces {
            for tab in state.tabs(in: space, .pinned) + state.tabs(in: space, .today) where tab.id != state.selectedTabID {
                let score = query.isEmpty ? 0 : max(FuzzyMatch.score(query, in: tab.displayTitle) ?? .min,
                                                    (FuzzyMatch.score(query, in: tab.url.absoluteString) ?? .min) - 50)
                guard query.isEmpty || score > .min else { continue }
                let spaceNote = space.id == state.activeSpaceID ? "" : " · \(space.name)"
                let id = tab.id
                tabRows.append((score, CommandItem(
                    id: "tab-\(tab.id)", kind: .tab, title: tab.displayTitle,
                    subtitle: "Switch to tab\(spaceNote)", symbol: "square.on.square", faviconURL: tab.faviconURL, pageURL: tab.url
                ) { [weak self] in self?.store.send(.selectTab(id)) }))
            }
        }
        rows += tabRows.sorted { $0.0 > $1.0 }.prefix(query.isEmpty ? 5 : 6).map(\.1)

        // Commands.
        var commands: [CommandItem] = []
        func command(_ id: String, _ title: String, _ symbol: String, _ run: @escaping @MainActor () -> Void) {
            commands.append(CommandItem(id: id, kind: .command, title: title, symbol: symbol, perform: run))
        }
        for (pkg, cmd) in packages.commands(for: state.selectedTab?.url) {
            let title = cmd.title
            commands.append(CommandItem(id: "pkg-\(pkg.id)-\(cmd.id)", kind: .command, title: title,
                                        subtitle: cmd.subtitle ?? pkg.manifest.name, symbol: "puzzlepiece.extension") { [weak self] in
                self?.runPackageCommand(packageID: pkg.id, commandID: cmd.id, title: title)
            })
        }
        command("packages", "Show packages folder", "folder") { [weak self] in self?.packages.revealInFinder() }
        command("reopen", "Reopen closed tab", "arrow.uturn.backward") { [weak self] in self?.store.send(.reopenClosedTab) }
        command("new-space", "New Space", "plus.square.on.square") { [weak self] in
            self?.store.send(.createSpace(name: "Space \((self?.store.state.spaces.count ?? 0) + 1)"))
        }
        command("mcp", "Copy Claude Code connection command", "point.3.connected.trianglepath.dotted") { [weak self] in
            self?.copyMCPCommand()
        }
        if !prompts.trustedClients.isEmpty {
            command("revoke", "Ask before agents act again", "hand.raised") { [weak self] in self?.prompts.revokeTrust() }
        }
        command("devtools", "Developer tools", "hammer") { [weak self] in self?.showDeveloperTools() }
        command("settings", "Settings", "gearshape") { [weak self] in self?.openSettings() }
        command("sidebar", "Toggle sidebar", "sidebar.left") { [weak self] in self?.toggleSidebar() }
        if let selected = state.selectedTabID {
            let favorite = state.isFavorite(selected)
            command("favorite", favorite ? "Remove from favorites" : "Add to favorites", favorite ? "star.slash" : "star") { [weak self] in
                self?.store.send(.toggleFavorite(selected))
            }
        }
        for login in passwords.logins(for: state.selectedTab?.url) {
            commands.append(CommandItem(id: "fill-\(login.id)", kind: .command, title: "Fill password",
                                        subtitle: login.username.isEmpty ? login.displayHost : login.username, symbol: "key.fill") { [weak self] in
                self?.fillLogin(login)
            })
        }
        command("passwords", "Passwords", "key") { [weak self] in self?.openSettings("passwords") }
        command("appearance", "Themes and appearance", "paintbrush") { [weak self] in self?.openSettings("appearance") }
        for theme in preferences.themes {
            command("theme-\(theme.id)", "Theme: \(theme.name)", "paintpalette") { [weak self] in self?.preferences.themeID = theme.id }
        }
        command("clear-today", "Clear Today tabs", "arrow.down.to.line") { [weak self] in self?.store.send(.clearToday) }
        for source in ImportSource.allCases where source.isAvailable {
            command("import-\(source.rawValue)", "Import from \(source.rawValue)", "square.and.arrow.down") { [weak self] in
                self?.importBrowser(source)
            }
        }

        // An empty bar shows only your tabs; commands appear as you type.
        if !query.isEmpty {
            rows += commands
                .compactMap { item in FuzzyMatch.score(query, in: item.title).map { ($0, item) } }
                .sorted { $0.0 > $1.0 }
                .prefix(4)
                .map(\.1)
        }
        return rows
    }
}
