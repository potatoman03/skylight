import AppKit
import SkylightBrowser
import SkylightCEF
import SkylightCore
import SkylightKit
import SkylightUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let paths: AppPaths
    private var browser: Browser?
    private var window: NSWindow?
    private var settings: SettingsWindowController?
    private var quitting = false

    init(paths: AppPaths) {
        self.paths = paths
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// Chromium is ready: build the browser and show the window.
    func engineDidStart() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        // Development runs (SKYLIGHT_DEV) keep passwords in memory, away from your Keychain.
        let credentials: CredentialStore = ProcessInfo.processInfo.environment["SKYLIGHT_DEV"] != nil
            ? MemoryCredentialStore.demo() : KeychainCredentialStore()
        let browser = Browser(engine: CEFEngine(support: paths.engineRoot.appending(path: "Skylight")), paths: paths, version: version, credentials: credentials)
        self.browser = browser
        NSApp.mainMenu = MainMenu.build(target: self)
        CEFRuntime.onTerminate { [weak self] in self?.quit() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // SwiftUI's toolbar and title become the window's own: one compact unified NSToolbar.
        let root = NSHostingController(rootView: RootView().environment(browser))
        root.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = root
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        // The sidebar button sits right after the traffic lights, outside the toolbar's layout, so it
        // stays put when the sidebar opens or closes.
        let toggle = NSTitlebarAccessoryViewController()
        toggle.layoutAttribute = .leading
        let toggleView = NSHostingView(rootView: SidebarToggle().environment(browser))
        toggleView.frame = NSRect(x: 0, y: 0, width: 36, height: 38)
        toggle.view = toggleView
        window.addTitlebarAccessoryViewController(toggle)
        window.delegate = self
        browser.showSettings = { [weak self, weak browser] section in
            guard let self, let browser else { return }
            if settings == nil { settings = SettingsWindowController(browser: browser) }
            settings?.show(section)
        }
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.setFrameAutosaveName("SkylightMain")
        if !window.setFrameUsingName("SkylightMain") { window.center() }
        self.window = window

        browser.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if browser.store.state.selectedTab == nil { browser.presentCommandBar(.newTab) }
    }

    /// Close every page, then stop the message loop. Chromium must not shut down with pages open.
    func quit() {
        guard !quitting else { return }
        quitting = true
        window?.orderOut(nil)
        guard let browser else { return CEFRuntime.quit() }
        browser.shutdown { CEFRuntime.quit() }
    }

    func browserWillExit() {
        browser?.store.flush()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        quit()
        return false
    }

    // MARK: - Menu actions

    private var store: BrowserStore? { browser?.store }
    private var selected: TabID? { store?.state.selectedTabID }

    @objc func newTab(_ sender: Any?) { browser?.presentCommandBar(.newTab) }
    @objc func openLocation(_ sender: Any?) { browser?.presentCommandBar(.editCurrent) }

    @objc func closeTab(_ sender: Any?) {
        if browser?.commandBar.isPresented == true { return browser?.dismissCommandBar() ?? () }
        guard let id = selected else { return }
        withAnimation(.smooth(duration: 0.28)) { _ = store?.send(.closeTab(id)) }
    }

    @objc func reopenTab(_ sender: Any?) { store?.send(.reopenClosedTab) }
    @objc func reload(_ sender: Any?) { if let id = selected { store?.send(.reload(id)) } }
    @objc func stopLoading(_ sender: Any?) { if let id = selected { store?.send(.stop(id)) } }
    @objc func goBack(_ sender: Any?) { if let id = selected { store?.send(.goBack(id)) } }
    @objc func goForward(_ sender: Any?) { if let id = selected { store?.send(.goForward(id)) } }
    @objc func pictureInPicture(_ sender: Any?) { browser?.togglePictureInPicture() }
    @objc func newSplitTab(_ sender: Any?) { if selected != nil { browser?.presentCommandBar(.split) } }
    @objc func nextPane(_ sender: Any?) { browser?.focusPane(offset: 1) }
    @objc func previousPane(_ sender: Any?) { browser?.focusPane(offset: -1) }
    @objc func rotateSplit(_ sender: Any?) { if let id = selected { store?.send(.rotateSplit(id)) } }
    @objc func separateSplit(_ sender: Any?) { if let id = selected { store?.send(.dissolveSplit(id)) } }
    @objc func togglePin(_ sender: Any?) { if let id = selected { store?.send(.togglePin(id)) } }
    @objc func nextTab(_ sender: Any?) { store?.send(.selectAdjacentTab(offset: 1)) }
    @objc func previousTab(_ sender: Any?) { store?.send(.selectAdjacentTab(offset: -1)) }
    @objc func nextSpace(_ sender: Any?) { store?.send(.switchSpaceByOffset(1)) }
    @objc func previousSpace(_ sender: Any?) { store?.send(.switchSpaceByOffset(-1)) }
    @objc func newSpace(_ sender: Any?) { store?.send(.createSpace(name: "Space \((store?.state.spaces.count ?? 0) + 1)")) }
    @objc func newFolder(_ sender: Any?) {
        withAnimation(.smooth(duration: 0.28)) { browser?.newFolder() }
    }
    @objc func developerTools(_ sender: Any?) { browser?.showDeveloperTools() }
    @objc func copyURL(_ sender: Any?) {
        guard let url = store?.state.selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        browser?.toasts.show("Copied link", symbol: "link")
    }
    @objc func boostSite(_ sender: Any?) { browser?.createBoostForCurrentSite() }
    @objc func showPackages(_ sender: Any?) { browser?.packages.revealInFinder() }
    @objc func copyAgentCommand(_ sender: Any?) { browser?.copyMCPCommand() }

    @objc func switchToSpace(_ sender: NSMenuItem) {
        guard let spaces = store?.state.spaces, spaces.indices.contains(sender.tag) else { return }
        store?.send(.switchSpace(spaces[sender.tag].id))
    }

    @objc func close(_ sender: Any?) { quit() }

    @objc func showSettings(_ sender: Any?) { browser?.openSettings() }

    @objc func toggleSidebar(_ sender: Any?) {
        withAnimation { browser?.toggleSidebar() }
    }
    @objc func toggleFavorite(_ sender: Any?) { if let id = selected { store?.send(.toggleFavorite(id)) } }
    @objc func clearToday(_ sender: Any?) {
        withAnimation(.smooth(duration: 0.28)) { _ = store?.send(.clearToday) }
    }
    @objc func importFrom(_ sender: NSMenuItem) {
        if let source = (sender.representedObject as? String).flatMap(Browser.ImportSource.init(rawValue:)) {
            browser?.importBrowser(source)
        }
    }
    @objc func importPasswordsCSV(_ sender: Any?) { browser?.openSettings("passwords") }
}
