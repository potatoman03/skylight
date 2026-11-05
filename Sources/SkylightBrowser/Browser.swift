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
    public let extensions: ExtensionService
    public let media = MediaService()
    public private(set) var mcpConnection: MCPConnection?
    /// The Space being renamed, if the rename alert is up.
    public var renameSpace: SpaceID?
    /// The Space whose icon, color and tint are being chosen in the sidebar's popover.
    public var customizingSpace: SpaceID?
    /// The folder whose name is being edited in the sidebar, as when it's just been made.
    public var renameFolder: String?
    /// The tab whose name is being edited in the sidebar.
    public var renameTab: TabID?
    /// Whether the keyboard shortcuts sheet is up.
    public var showShortcuts = false
    /// Whether Skylight's menu, from the Space button in the sidebar, is open.
    public var showsMainMenu = false
    /// A new version, downloaded and waiting for a restart. The app's updater sets it.
    public var readyUpdate: ReadyUpdate?
    /// Opens the Settings window; the app provides it.
    @ObservationIgnored public var showSettings: @MainActor (String?) -> Void = { _ in }

    public var omnibox: Omnibox { preferences.omnibox }
    @ObservationIgnored private let engine: WebEngine
    @ObservationIgnored private let mcp: MCPServer

    public init(engine: WebEngine, paths: AppPaths, version: String, credentials: CredentialStore) {
        self.engine = engine
        let preferences = Preferences(fileURL: paths.preferencesFile)
        self.preferences = preferences
        self.passwords = PasswordService(store: credentials, toasts: toasts,
                                         neverFile: paths.root.appending(path: "password-exceptions.json"))
        self.extensions = ExtensionService(host: engine.extensions, root: paths.root, toasts: toasts)
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
            self?.media.pageWentAway(id)
            if tabClosed { self?.prompts.dismissAll(for: id) }
        }
        commandBar.source = self
        extensions.makePage = { [weak self] url, delegate in
            guard let self else { return nil }
            return self.engine.makePage(url: url, profile: self.pages.profile(for: self.store.state.activeSpace.profileID), delegate: delegate)
        }
        extensions.openTab = { [weak self] url in self?.store.send(.openTab(url)) }
        extensions.currentTabs = { [weak self] in
            guard let self else { return ([], nil) }
            let profile = self.store.state.activeSpace.profileID
            let visible = self.pages.awake.filter { $0.profile == profile }
            let active = self.pages.visibleTabID.flatMap { id in visible.first { $0.tab == id }?.page }
            return (visible.map(\.page), active)
        }
        extensions.tabGroups = { [weak self] in
            guard let self else { return [] }
            return Dictionary(grouping: self.pages.awake, by: \.profile).map { profile, awake in
                ExtensionTabs(profile: self.pages.profile(for: profile), pages: awake.map(\.page),
                              active: awake.first { $0.tab == self.pages.visibleTabID }?.page)
            }
        }
        passwords.profiles = { [weak self] in self?.store.state.profiles.map(\.id) ?? [.standard] }
        passwords.reload()
        extensions.showingDefaultProfile = { [weak self] in self?.store.state.activeSpace.profileID == .standard }
        extensions.hasOtherProfiles = { [weak self] in (self?.store.state.profiles.count ?? 0) > 1 }
        media.page = { [weak self] id in self?.pages.page(for: id) }
        media.autoPictureInPicture = { preferences.autoPictureInPicture }
        var shown: [TabID] = []
        pages.onPagesChange = { [weak self] in
            guard let self else { return }
            self.extensions.syncTabs()
            if shown != self.pages.visibleTabIDs {
                self.media.visibleTabsChanged(from: shown, to: self.pages.visibleTabIDs)
                shown = self.pages.visibleTabIDs
            }
        }
        packages.onScriptsChange = { [weak self] _ in self?.updatePageScripts() }
        packages.evaluateEverywhere = { [weak self] script in
            for page in self?.pages.awakePages ?? [] { Task { _ = try? await page.evaluate(script) } }
        }
    }

    public func start() {
        // Settings used to open as a tab; it has its own window now.
        for tab in store.state.tabs.values where tab.url.isSkylightPage { store.send(.removeTab(tab.id)) }
        preferences.applyAppearance()
        packages.start()
        updatePageScripts()
        startPages()
        // Once things have settled, then every few hours.
        Task { [extensions] in
            try? await Task.sleep(for: .seconds(60))
            await extensions.keepUpdated()
        }
        mcp.start { [weak self] connection in self?.mcpConnection = connection }
    }

    /// Pages wait for extensions (briefly), so content scripts reach the first page too.
    private func startPages() {
        guard extensions.isAvailable, !extensions.enabled.isEmpty else { return pages.start() }
        var started = false
        let begin = { [weak self] in
            guard !started else { return }
            started = true
            self?.pages.start()
        }
        Task { await extensions.start(); begin() }
        Task { try? await Task.sleep(for: .seconds(1.5)); begin() }
    }

    /// Closes every page, saves, then calls `completion` once the engine may shut down.
    public func shutdown(completion: @escaping @MainActor () -> Void) {
        store.flush()
        mcp.stop()
        pages.closeAll(completion: completion)
    }

    private func updatePageScripts() {
        engine.setPageScripts(AgentService.pageScripts + [PasswordService.pageScript, MediaService.pageScript, ExtensionService.storePageScript] + packages.scripts)
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
        open(url, inNewTab: inNewTab)
    }

    /// Opens links from other apps (or web pages and files opened with Skylight) as new tabs at the
    /// top of Today, showing the last one.
    public func openExternal(_ urls: [URL]) {
        let usable = urls.filter { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
        guard !usable.isEmpty else { return }
        if commandBar.isPresented { commandBar.dismiss() }
        for (i, url) in usable.enumerated() {
            store.send(.openTab(url, placement: .top, select: i == usable.count - 1))
        }
    }

    /// ⌘L edits the address in the toolbar; ⌘T (and a new split pane) opens the command bar in the
    /// middle of the page.
    public func presentCommandBar(_ mode: CommandBarModel.Mode) {
        let query = mode == .editCurrent ? (store.state.selectedTab?.url.absoluteString ?? "") : ""
        commandBar.present(mode, query: query)
    }

    public func dismissCommandBar() {
        guard commandBar.isPresented else { return }
        commandBar.dismiss()
        pages.focusVisiblePage()
    }

    /// Opens `url` beside the selected tab, in a split.
    public func openInSplit(_ url: URL) {
        guard let selected = store.state.selectedTabID, let id = store.send(.openTab(url, placement: .afterSelected)).openedTabID else {
            return open(url, inNewTab: true)
        }
        store.send(.splitTab(id, beside: selected, edge: .trailing))
    }

    private func open(_ url: URL, inNewTab: Bool) {
        if !inNewTab, let id = store.state.selectedTabID {
            store.send(.navigate(id, url))
        } else {
            store.send(.openTab(url))
        }
    }

    /// Puts the focused tab's video into Picture in Picture, or brings it back.
    public func togglePictureInPicture() {
        guard let id = store.state.selectedTabID else { return }
        guard media.state(of: id).hasVideo || media.state(of: id).inPictureInPicture else {
            return toasts.show("No video on this page", symbol: "pip")
        }
        media.togglePictureInPicture(id)
    }

    /// Moves focus to the next (or previous) pane of the selected tab's split.
    public func focusPane(offset: Int) {
        let state = store.state
        guard let id = state.selectedTabID, let split = state.activeSpace.split(containing: id),
              let index = split.tabs.firstIndex(of: id) else { return }
        store.send(.selectTab(split.tabs[(index + offset + split.tabs.count) % split.tabs.count]))
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
        guard credential.profile == store.state.profileID(forTab: id) else { return }
        passwords.fill(credential, in: page, url: store.state.tabs[id]?.url)
    }

    /// Deletes a profile. Its Spaces and saved passwords move to the default one.
    public func deleteProfile(_ id: ProfileID) {
        guard id != .standard else { return }
        passwords.moveLogins(from: id)
        store.send(.deleteProfile(id))
    }

    public func duplicateSpace() {
        store.send(.duplicateSpace(store.state.activeSpaceID))
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


    /// Shows the Settings window, at `section` (`"passwords"`, `"extensions"`…) if given.
    public func openSettings(_ section: String? = nil) { showSettings(section) }

    /// Opens the popover for a Space's look. It hangs off the Space's header, so that Space has to
    /// be the one showing, in a sidebar that's open.
    public func customizeSpace(_ id: SpaceID) {
        if id != store.state.activeSpaceID { store.send(.switchSpace(id)) }
        preferences.sidebarCollapsed = false
        customizingSpace = id
    }

    /// Makes a folder in the active Space (holding `tabs`, if any) and starts naming it.
    public func newFolder(with tabs: [TabID] = []) {
        let id = UUID().uuidString
        store.send(.createFolder(id: id, space: store.state.activeSpaceID, name: "New Folder", tabs: tabs))
        renameFolder = id
    }

    public func toggleSidebar() {
        sidebarPeeking = false
        preferences.sidebarCollapsed.toggle()
    }

    /// The hidden sidebar is out for a moment, because the pointer went to the window's edge.
    public var sidebarPeeking = false

    /// The sidebar is on screen: shown, or out for a peek.
    public var showsSidebar: Bool { !preferences.sidebarCollapsed || sidebarPeeking }

    public func toggleMainMenu() {
        if !showsMainMenu { dismissCommandBar() }
        showsMainMenu.toggle()
    }

    /// Where downloads go: the engine saves them straight to this folder.
    public func showDownloads() {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(folder)
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
            return passwords.handle(message, tab: id, url: store.state.tabs[id]?.url, profile: store.state.profileID(forTab: id))
        case let type? where type.hasPrefix("media."):
            return media.handle(message, tab: id)
        case "extensions.storeStatus", "extensions.storeInstall":
            return await extensions.handleStore(message, tabURL: store.state.tabs[id]?.url)
        case let type? where type.hasPrefix("extensions."):
            // For extensions' own pages, not the web.
            guard store.state.tabs[id]?.url.scheme == "chrome-extension" else { throw WebEngineError.script("Unknown message.") }
            return extensions.handle(message, from: pages.page(for: id))
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
        let newTab = mode != .editCurrent
        let split = mode == .split

        if let interpretation = omnibox.interpret(query) {
            let url = interpretation.url
            let go: @MainActor () -> Void = { [weak self] in
                if split { self?.openInSplit(url) } else { self?.open(url, inNewTab: newTab) }
            }
            switch interpretation {
            case let .address(url):
                rows.append(CommandItem(id: "open", kind: .address, title: url.absoluteString,
                                        subtitle: split ? "Open in split view" : newTab ? "Open in a new tab" : "Go",
                                        symbol: split ? "rectangle.split.2x1" : "arrow.up.right", pageURL: url, perform: go))
            case let .search(text, _):
                rows.append(CommandItem(id: "search", kind: .search, title: text, subtitle: split ? "Search in split view" : "Search",
                                        symbol: "magnifyingglass", perform: go))
            }
        }

        // Open tabs, any Space.
        let state = store.state
        var tabRows: [(Int, CommandItem)] = []
        let favoritesSpace = Space(id: state.activeSpaceID, name: "Favorites", hue: 0, today: state.favorites)
        for space in [favoritesSpace] + state.spaces {
            for tab in state.tabs(in: space, .pinned) + state.tabs(in: space, .today) where tab.id != state.selectedTabID {
                guard let score = query.isEmpty ? 0 : FuzzyMatch.score(query, title: tab.displayTitle, url: tab.url.absoluteString)
                else { continue }
                let spaceNote = space.id == state.activeSpaceID ? "" : " · \(space.name)"
                let id = tab.id
                if split, tab.url.isSkylightPage || state.activeSpace.split(containing: id) != nil { continue }
                let selected = state.selectedTabID
                tabRows.append((score, CommandItem(
                    id: "tab-\(tab.id)", kind: .tab, title: tab.displayTitle,
                    subtitle: split ? "Show beside this tab\(spaceNote)" : "Switch to tab\(spaceNote)",
                    symbol: split ? "rectangle.split.2x1" : "square.on.square", faviconURL: tab.faviconURL, pageURL: tab.url
                ) { [weak self] in
                    guard let self else { return }
                    if split, let selected {
                        if !state.isFavorite(id), state.space(containing: id)?.id != state.activeSpaceID {
                            self.store.send(.moveTabToSpace(id, state.activeSpaceID))
                        }
                        self.store.send(.splitTab(id, beside: selected, edge: .trailing))
                    } else {
                        self.store.send(.selectTab(id))
                    }
                }))
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
        command("duplicate-space", "Duplicate Space", "plus.square.on.square") { [weak self] in self?.duplicateSpace() }
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
            if media.state(of: selected).hasVideo || media.state(of: selected).inPictureInPicture {
                command("pip", "Picture in Picture", "pip.enter") { [weak self] in self?.togglePictureInPicture() }
            }
            if state.activeSpace.split(containing: selected) != nil {
                command("split-rotate", "Rotate split", "rectangle.split.2x1") { [weak self] in self?.store.send(.rotateSplit(selected)) }
                command("split-separate", "Separate split", "rectangle") { [weak self] in self?.store.send(.dissolveSplit(selected)) }
            }
            let favorite = state.isFavorite(selected)
            command("favorite", favorite ? "Remove from favorites" : "Add to favorites", favorite ? "star.slash" : "star") { [weak self] in
                self?.store.send(.toggleFavorite(selected))
            }
        }
        for login in passwords.logins(for: state.selectedTab?.url, in: state.activeSpace.profileID) {
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

/// A downloaded update waiting to be installed. The app's updater fills it in, so nothing outside
/// the app target knows how updates arrive.
public struct ReadyUpdate {
    /// What people call it, like "0.1.2".
    public let version: String
    /// Installs it and relaunches Skylight, through the normal quit. Call it on the main thread.
    public let install: () -> Void

    public init(version: String, install: @escaping () -> Void) {
        self.version = version
        self.install = install
    }
}
