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
    public private(set) var mcpConnection: MCPConnection?

    @ObservationIgnored public let omnibox = Omnibox()
    @ObservationIgnored private let engine: WebEngine
    @ObservationIgnored private let mcp: MCPServer

    public init(engine: WebEngine, paths: AppPaths, version: String) {
        self.engine = engine
        let store = BrowserStore(persistence: JSONFileStateStore(fileURL: paths.stateFile))
        self.store = store
        self.pages = PageCoordinator(engine: engine, paths: paths, store: store)
        self.packages = PackageService(directory: paths.packagesDirectory)
        self.agents = AgentService(store: store, pages: pages, packages: packages, omnibox: omnibox, approvals: prompts)
        self.mcp = MCPServer(
            catalog: agents.hub,
            info: .init(name: "skylight", version: version, instructions: Self.agentInstructions),
            connectionFile: paths.mcpConnectionFile)

        store.effectHandler = pages
        pages.sink = self
        pages.onPageGone = { [weak self] id, tabClosed in
            self?.agents.forgetTab(id)
            if tabClosed { self?.prompts.dismissAll(for: id) }
        }
        commandBar.source = self
        packages.onScriptsChange = { [weak self] _ in self?.updatePageScripts() }
        packages.evaluateEverywhere = { [weak self] script in
            for page in self?.pages.awakePages ?? [] { Task { _ = try? await page.evaluate(script) } }
        }
    }

    public func start() {
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
        engine.setPageScripts(AgentService.pageScripts + packages.scripts)
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
                                        subtitle: newTab ? "Open in a new tab" : "Go", symbol: "arrow.up.right") { [weak self] in
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
        for space in state.spaces {
            for tab in state.tabs(in: space, .pinned) + state.tabs(in: space, .today) where tab.id != state.selectedTabID {
                let score = query.isEmpty ? 0 : max(FuzzyMatch.score(query, in: tab.displayTitle) ?? .min,
                                                    (FuzzyMatch.score(query, in: tab.url.absoluteString) ?? .min) - 50)
                guard query.isEmpty || score > .min else { continue }
                let spaceNote = space.id == state.activeSpaceID ? "" : " · \(space.name)"
                let id = tab.id
                tabRows.append((score, CommandItem(
                    id: "tab-\(tab.id)", kind: .tab, title: tab.displayTitle,
                    subtitle: "Switch to tab\(spaceNote)", symbol: "square.on.square", faviconURL: tab.faviconURL
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
        command("boost", "Boost this site", "paintbrush") { [weak self] in self?.createBoostForCurrentSite() }
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

        if query.isEmpty {
            rows += commands.prefix(3)
        } else {
            rows += commands
                .compactMap { item in FuzzyMatch.score(query, in: item.title).map { ($0, item) } }
                .sorted { $0.0 > $1.0 }
                .prefix(4)
                .map(\.1)
        }
        return rows
    }
}
