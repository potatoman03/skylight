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
    private let paths: AppPaths
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
    /// The welcome sheet is up.
    public var showsWelcome = false
    /// The history sheet is up.
    public var showHistory = false
    /// Whether Skylight's menu, from the Space button in the sidebar, is open.
    public var showsMainMenu = false
    /// The New Space sheet, while it's up.
    public var spaceSetup: SpaceSetupRequest?
    /// A new version, downloaded and waiting for a restart. The app's updater sets it.
    public var readyUpdate: ReadyUpdate?
    /// Opens the Settings window; the app provides it.
    @ObservationIgnored public var showSettings: @MainActor (String?) -> Void = { _ in }
    /// Brings the browser window forward; the app provides it.
    @ObservationIgnored public var showWindow: @MainActor () -> Void = {}

    public var omnibox: Omnibox { preferences.omnibox }
    public let autofill: AutofillService
    @ObservationIgnored public let history: HistoryStore
    /// Where each tab last went, so a title lands on the right page and a reload isn't a visit.
    @ObservationIgnored private var lastVisit: [TabID: URL] = [:]
    @ObservationIgnored private let engine: WebEngine
    @ObservationIgnored private let mcp: MCPServer

    public init(engine: WebEngine, paths: AppPaths, version: String, credentials: CredentialStore, autofillStore: AutofillStore) {
        self.engine = engine
        self.paths = paths
        let preferences = Preferences(fileURL: paths.preferencesFile)
        self.preferences = preferences
        self.passwords = PasswordService(store: credentials, toasts: toasts,
                                         neverFile: paths.root.appending(path: "password-exceptions.json"))
        self.extensions = ExtensionService(host: engine.extensions, root: paths.root, toasts: toasts)
        self.autofill = AutofillService(store: autofillStore, toasts: toasts)
        self.history = HistoryStore(file: paths.root.appending(path: "History.sqlite"))
        let store = BrowserStore(persistence: JSONFileStateStore(fileURL: paths.stateFile))
        self.store = store
        self.pages = PageCoordinator(engine: engine, paths: paths, store: store)
        self.packages = PackageService(directory: paths.packagesDirectory)
        self.agents = AgentService(store: store, pages: pages, packages: packages, omnibox: { preferences.omnibox }, approvals: prompts)
        self.mcp = MCPServer(
            catalog: agents.hub,
            info: .init(name: "skylight", version: version, instructions: Self.agentInstructions),
            connectionFile: paths.mcpConnectionFile)

        prompts.siteOfCall = { [weak self] in self?.agents.site(of: $0) }
        pages.archiveAfter = { preferences.archiveAfterHours * 60 * 60 }
        store.effectHandler = pages
        pages.sink = self
        pages.onVisit = { [weak self] id, url, title in self?.noteVisit(id, url: url, title: title) }
        autofill.profiles = { store.state.profiles.filter { $0.passwordsFrom == nil }.map(\.id) }
        autofill.reload()
        pages.onPageGone = { [weak self] id, tabClosed in
            self?.lastVisit[id] = nil
            self?.agents.forgetTab(id)
            self?.passwords.pageWentAway(id)
            self?.media.pageWentAway(id)
            if tabClosed { self?.prompts.dismissAll(for: id) }
        }
        commandBar.source = self
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
        moveChromiumSessions(from: paths)
        // Settings used to open as a tab; it has its own window now.
        for tab in store.state.tabs.values where tab.url.isSkylightPage { store.send(.removeTab(tab.id)) }
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

    /// Saves and closes every page.
    public func shutdown() {
        store.flush()
        mcp.stop()
        pages.closeAll()
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

    /// No tab, or a new one that hasn't gone anywhere yet.
    public var showsEmptyPage: Bool { store.state.selectedTab?.isBlank ?? true }

    /// A new tab, with the field on its empty page ready for an address.
    public func newTab() {
        if store.state.selectedTab?.isBlank != true { store.send(.openTab(Tab.blankURL)) }
        presentCommandBar(.newTab)
    }

    /// ⌘L edits the address in the toolbar; an empty page and a new split pane have the command
    /// bar in the middle of the page.
    public func presentCommandBar(_ mode: CommandBarModel.Mode) {
        // On an empty page there's no address to edit, only its field.
        let mode = mode == .editCurrent && showsEmptyPage ? .newTab : mode
        let address = mode == .editCurrent ? store.state.selectedTab?.url : nil
        commandBar.present(mode, query: address.map(omnibox.short) ?? "")
    }

    public func copyLink() {
        guard let url = store.state.selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        toasts.show("Copied link", symbol: "link")
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
        guard credential.profile == store.state.passwordProfile(for: store.state.profileID(forTab: id)) else { return }
        passwords.fill(credential, in: page, url: store.state.tabs[id]?.url)
    }

    /// Fills the selected tab's form with a saved address.
    public func fillAddress(_ address: AutofillAddress) {
        guard let id = store.state.selectedTabID, let page = pages.page(for: id) else { return }
        autofill.fill(address, in: page, url: store.state.tabs[id]?.url)
    }

    /// Fills the selected tab's form with a saved card, once you've confirmed it's you.
    public func fillCard(_ card: AutofillCard) async {
        guard let id = store.state.selectedTabID, let page = pages.page(for: id) else { return }
        let profile = store.state.passwordProfile(for: store.state.profileID(forTab: id))
        await autofill.fill(card, in: page, profile: profile, confirm: { await self.passwords.authenticate($0) },
                            currentURL: { self.store.state.tabs[id]?.url })
    }

    private func noteVisit(_ id: TabID, url: URL?, title: String?) {
        let profile = store.state.profileID(forTab: id)
        if let url, !["http", "https"].contains(url.scheme ?? "") {
            // Skylight's own pages aren't history, and their titles aren't the last page's.
            lastVisit[id] = nil
        } else if let url, url != lastVisit[id] {
            lastVisit[id] = url
            history.record(url, title: title ?? "", in: profile)
        } else if let title, !title.isEmpty, let url = lastVisit[id] {
            history.setTitle(title, of: url, in: profile)
        }
    }

    /// Deletes a profile and its history. Its Spaces, passwords, addresses and cards move to the
    /// default one.
    public func deleteProfile(_ id: ProfileID) {
        guard id != .standard else { return }
        passwords.moveLogins(from: id)
        autofill.move(from: id)
        history.clear(id)
        store.send(.deleteProfile(id))
        Task { await pages.deleteProfile(id) }
    }

    public func duplicateSpace() {
        store.send(.duplicateSpace(store.state.activeSpaceID))
    }

    /// Asks what a new Space should keep from the current one.
    public func newSpace() {
        let state = store.state
        askForSpaceSetup(space: nil, name: "Space \(state.spaces.count + 1)", source: state.activeSpace)
    }

    /// Asks what a Space should keep when it moves to a profile of its own.
    public func newProfile(for id: SpaceID) {
        guard let space = store.state.spaces.first(where: { $0.id == id }) else { return }
        askForSpaceSetup(space: id, name: space.name, source: space)
    }

    private func askForSpaceSetup(space: SpaceID?, name: String, source: Space) {
        Task {
            let signedIn = await pages.signedInSites(in: source.profileID)
            showWindow()
            spaceSetup = SpaceSetupRequest(space: space, name: name, sourceName: source.name,
                                           source: source.profileID, signedIn: signedIn)
        }
    }

    /// Closes the New Space sheet and does what it says. A blank name takes the suggested one.
    public func finishSpaceSetup(name: String, setup: SpaceSetup) {
        guard let request = spaceSetup else { return }
        spaceSetup = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? request.name : trimmed
        if request.space == nil {
            preferences.newSpaceSetup = setup
            guard !setup.sharesEverything else {
                store.send(.createSpace(name: name))
                return
            }
        }
        Task { await separate(request, name: name, setup: setup) }
    }

    /// Makes the profile and fills it before anything opens in it, so a page's first load is
    /// already signed in. Whatever can't be copied just means signing in again.
    private func separate(_ request: SpaceSetupRequest, name: String, setup: SpaceSetup) async {
        store.send(.createProfile(name: name, passwordsFrom: setup.passwords ? request.source : nil))
        guard let profile = store.state.profiles.last?.id else { return }
        let ids = extensions.enabled.map(\.id).filter { !setup.skippedExtensions.contains($0) }
        do {
            try await pages.copyExtensionData(ids, from: request.source, to: profile)
        } catch {
            toasts.show("Couldn't bring along your extensions. Sign in to them again here.", symbol: "exclamationmark.triangle")
        }
        let sites = request.signedIn.filter(setup.sites.contains)
        if !sites.isEmpty, await pages.copyCookies(sites.flatMap(\.domains), from: request.source, to: profile) == 0 {
            toasts.show("Couldn't bring along your sign-ins. Sign in again here.", symbol: "exclamationmark.triangle")
        }
        if let space = request.space {
            store.send(.assignProfile(space, profile))
        } else {
            store.send(.createSpace(name: name, profile: profile))
        }
    }

    public enum ImportSource: String, CaseIterable, Sendable {
        case arc = "Arc", aside = "Aside", helium = "Helium", chrome = "Chrome", dia = "Dia", brave = "Brave", edge = "Edge", vivaldi = "Vivaldi"

        /// Where the browser keeps what we import: Arc's sidebar, or a Chromium `Bookmarks` file.
        public var file: URL {
            let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
            return switch self {
            case .arc: BrowserImporters.arcFile
            case .aside: support.appending(path: "Aside/Default/Bookmarks")
            case .helium: support.appending(path: "net.imput.helium/Default/Bookmarks")
            case .chrome: support.appending(path: "Google/Chrome/Default/Bookmarks")
            case .dia: support.appending(path: "Dia/User Data/Default/Bookmarks")
            case .brave: support.appending(path: "BraveSoftware/Brave-Browser/Default/Bookmarks")
            case .edge: support.appending(path: "Microsoft Edge/Default/Bookmarks")
            case .vivaldi: support.appending(path: "Vivaldi/Default/Bookmarks")
            }
        }

        private static let everything = "passwords, sign-ins, extensions, history, addresses and cards"

        /// Where the same browser keeps its logins and cookies.
        public var chromium: ChromiumBrowser? { ChromiumBrowser.all.first { $0.id == rawValue.lowercased() } }

        public var isAvailable: Bool { FileManager.default.fileExists(atPath: file.path) || chromium?.isInstalled == true }

        /// The browsers on this Mac that can be imported from.
        public static var available: [ImportSource] { allCases.filter(\.isAvailable) }

        /// The one to suggest: the Mac's default browser if it can be imported, else Chrome, as
        /// the likeliest to hold someone's things.
        public static var preferred: ImportSource? {
            let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
                .flatMap { Bundle(url: $0)?.bundleIdentifier }
            let found = available
            return found.first { $0.chromium?.bundleIDs.contains(current ?? "") == true }
                ?? found.first { $0 == .chrome } ?? found.first
        }

        /// What can't leave, whichever the browser.
        public static let staysBehind = "Passkeys and cards kept in Google Pay stay behind"

        /// What comes over, for the import screen.
        public var summary: String {
            switch self {
            case .arc: "Spaces, pinned tabs, favorites, \(Self.everything)"
            case .aside: "Sidebar folders as Spaces, bookmarks, \(Self.everything)"
            default: "Bookmarks, \(Self.everything)"
            }
        }
    }

    /// How an import went, in a sentence.
    public struct ImportResult: Sendable {
        public var message: String
        /// Something didn't come over, and the message says what.
        public var failed: Bool
    }

    /// Brings Spaces, tabs, passwords and sign-ins over from another browser, into the Space on
    /// screen. Arc's other profiles become profiles here, keeping their own. macOS asks before
    /// Skylight can read that browser's key. `announcing` shows the result as a toast too.
    @discardableResult
    public func importBrowser(_ source: ImportSource, announcing: Bool = true) async -> ImportResult {
        var problem: String?
        var tabs = 0
        let profilesBefore = store.state.profiles.count
        // Each of the browser's profiles, and the profile here that gets its logins.
        var targets = source.chromium.map { [(browser: $0, profile: store.state.activeSpace.profileID)] } ?? []
        do {
            if FileManager.default.fileExists(atPath: source.file.path) {
                let data = try Data(contentsOf: source.file)
                var imported = source == .arc ? try BrowserImporters.arc(data)
                    : try BrowserImporters.chromium(data, browser: source.rawValue)
                if let file = source.chromium?.localState, let names = try? Data(contentsOf: file) {
                    imported.profileNames = BrowserImporters.chromiumProfileNames(names)
                }
                let before = store.state.tabs.count
                store.send(.importBrowserData(imported))
                tabs = store.state.tabs.count - before
                for folder in imported.profileFolders {
                    let name = imported.profileName(for: folder)
                    if let browser = source.chromium, let profile = store.state.profiles.first(where: { $0.name == name }) {
                        targets.append((browser.profile(folder), profile.id))
                    }
                }
            }
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Couldn't read \(source.rawValue)'s tabs."
        }

        var logins = 0
        var sites = Set<String>()
        var addresses = 0
        var cards = 0
        var pagesFound = 0
        do {
            let found = try await passwords.signIns(from: targets.map(\.browser))
            for (target, signIns) in zip(targets, found) {
                logins += passwords.save(signIns.credentials, into: store.state.passwordProfile(for: target.profile)).added
                if await pages.addCookies(signIns.cookies, to: target.profile) > 0 {
                    sites.formUnion(signIns.cookies.map(\.host))
                }
                let added = autofill.merge(signIns.autofill, into: store.state.passwordProfile(for: target.profile))
                addresses += added.addresses
                cards += added.cards
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "Couldn't read them."
            problem = "Passwords, sign-ins, addresses and cards stayed behind. \(reason)"
        }

        // These two need no key, so they come over even if that was refused.
        for target in targets {
            let file = target.browser.history
            let entries = (try? await Task.detached { try ChromiumHistoryImporter.read(history: file) }.value) ?? []
            pagesFound += history.add(entries, to: target.profile)
        }
        let wanted = targets.flatMap { target in
            ChromiumExtensions.storeIDs(in: target.browser.preferenceFiles.compactMap { try? Data(contentsOf: $0) })
        }
        let adopted = await extensions.adopt(wanted)

        var parts: [String] = []
        let profiles = store.state.profiles.count - profilesBefore
        if profiles > 0 { parts.append("\(profiles) profile\(profiles == 1 ? "" : "s")") }
        if tabs > 0 { parts.append("\(tabs) tab\(tabs == 1 ? "" : "s")") }
        if logins > 0 { parts.append("\(logins) password\(logins == 1 ? "" : "s")") }
        if !sites.isEmpty { parts.append("sign-ins for \(sites.count) site\(sites.count == 1 ? "" : "s")") }
        if adopted > 0 { parts.append("\(adopted) extension\(adopted == 1 ? "" : "s")") }
        if addresses > 0 { parts.append("\(addresses) address\(addresses == 1 ? "" : "es")") }
        if cards > 0 { parts.append("\(cards) card\(cards == 1 ? "" : "s")") }
        if pagesFound > 0 { parts.append("\(pagesFound.formatted()) page\(pagesFound == 1 ? "" : "s") of history") }
        let summary = parts.isEmpty ? nil : "Imported " + ListFormatter.localizedString(byJoining: parts) + " from \(source.rawValue)"
        let message = [summary, problem].compactMap(\.self).joined(separator: ". ")
        guard !message.isEmpty else {
            let same = "Everything from \(source.rawValue) is already here"
            if announcing { toasts.show(same, symbol: "square.and.arrow.down") }
            return ImportResult(message: same, failed: false)
        }
        if announcing { toasts.show(message, symbol: problem == nil ? "square.and.arrow.down" : "exclamationmark.triangle") }
        return ImportResult(message: message, failed: problem != nil)
    }

    /// Opens the welcome on a new install, and returns whether it did. Anyone else never needs it.
    public func welcomeIfNew() -> Bool {
        guard !preferences.finishedWelcome else { return false }
        guard WelcomeStep.isDue(for: store.state) else {
            preferences.finishedWelcome = true
            return false
        }
        showsWelcome = true
        return true
    }

    /// Closes the welcome, and leaves you ready to type if nothing's open.
    public func finishWelcome() {
        showsWelcome = false
        preferences.finishedWelcome = true
        if store.state.selectedTab == nil { presentCommandBar(.newTab) }
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
            return passwords.handle(message, tab: id, url: store.state.tabs[id]?.url,
                                    profile: store.state.passwordProfile(for: store.state.profileID(forTab: id)))
        case let type? where type.hasPrefix("media."):
            return media.handle(message, tab: id)
        case "extensions.storeStatus", "extensions.storeInstall":
            return await extensions.handleStore(message, tabURL: store.state.tabs[id]?.url)
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
        // A new tab is just the field until you type.
        if mode == .newTab, query.isEmpty { return [] }
        var rows: [CommandItem] = []
        // A new tab is already here, waiting to go somewhere.
        let newTab = mode != .editCurrent && !showsEmptyPage
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
                rows.append(CommandItem(id: "search", kind: .search, title: text, subtitle: split ? "Search in split view" : preferences.searchEngine.searchName,
                                        symbol: "magnifyingglass", perform: go))
            }
        }

        // Open tabs, any Space.
        let state = store.state
        var tabRows: [(Int, CommandItem)] = []
        for space in state.spaces {
            for tab in space.allTabIDs.compactMap({ state.tabs[$0] }) where tab.id != state.selectedTabID {
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

        // Where you've been, unless it's open already.
        let open = Set(state.tabs.values.map(\.url))
        for entry in history.suggestions(for: query, in: state.activeSpace.profileID, limit: 8).filter({ !open.contains($0.url) }).prefix(4) {
            let url = entry.url
            rows.append(CommandItem(id: "history-\(entry.id)", kind: .address, title: entry.displayTitle,
                                    subtitle: url.host() ?? url.absoluteString, symbol: "clock", pageURL: url) { [weak self] in
                if split { self?.openInSplit(url) } else { self?.open(url, inNewTab: newTab) }
            })
        }

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
        command("new-space", "New Space", "plus.square.on.square") { [weak self] in self?.newSpace() }
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
        for login in passwords.logins(for: state.selectedTab?.url, in: state.passwordProfile(for: state.activeSpace.profileID)) {
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
                Task { await self?.importBrowser(source) }
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
