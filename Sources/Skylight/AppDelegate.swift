import AppKit
import SkylightBrowser
import SkylightWebKit
import SkylightCore
import SkylightKit
import SkylightUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let paths: AppPaths
    private let demo: Bool
    private let development: Bool
    private var browser: Browser?
    private var window: NSWindow?
    private var settings: SettingsWindowController?
    private var updater: Updater?
    /// The window went full screen for a fullscreen video, so it leaves full screen with it.
    private var fullScreenForPage = false
    private var sidebarToggle: NSTitlebarAccessoryViewController?
    /// Links that arrived before the engine was ready, as when a click in another app launches Skylight.
    private var pendingURLs: [URL] = []

    init(paths: AppPaths, demo: Bool, development: Bool) {
        self.paths = paths
        self.demo = demo
        self.development = development
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        // Development runs (SKYLIGHT_DEV) keep passwords in memory, away from your Keychain.
        let credentials: CredentialStore = demo ? MemoryCredentialStore.demo() : KeychainCredentialStore()
        let autofill: AutofillStore = demo ? MemoryAutofillStore.demo() : KeychainAutofillStore()
        let browser = Browser(engine: WebKitEngine(), paths: paths, version: version, credentials: credentials, autofillStore: autofill)
        self.browser = browser
        updater = Updater(development: development, browser: browser)
        NSApp.mainMenu = MainMenu.build(target: self)
        ShortcutMap.apply(browser.preferences.shortcuts)

        let window = BrowserWindow(
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
        sidebarToggle = toggle
        browser.onWelcomeChange = { [weak self] showing in
            guard let toggle = self?.sidebarToggle else { return }
            // Back with the sidebar, after the welcome has faded.
            if showing { toggle.isHidden = true } else {
                toggle.view.alphaValue = 0
                toggle.isHidden = false
                NSAnimationContext.runAnimationGroup { $0.duration = 0.6; toggle.view.animator().alphaValue = 1 }
            }
        }
        window.delegate = self
        browser.pages.onFullscreenChange = { [weak self] fullscreen in self?.pageFullscreenChanged(fullscreen) }
        browser.showSettings = { [weak self, weak browser] section in
            guard let self, let browser else { return }
            if settings == nil { settings = SettingsWindowController(browser: browser) }
            settings?.show(section)
        }
        browser.showWindow = { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.setFrameAutosaveName("SkylightMain")
        if !window.setFrameUsingName("SkylightMain") { window.center() }
        self.window = window

        browser.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if !pendingURLs.isEmpty {
            browser.openExternal(pendingURLs)
            pendingURLs = []
        } else if !browser.welcomeIfNew(), browser.store.state.selectedTab == nil {
            browser.presentCommandBar(.newTab)
        }
    }

    /// Links from other apps when Skylight is the default browser, and web pages opened with it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let browser else { return pendingURLs.append(contentsOf: urls) }
        // The page would open behind the sheet.
        if browser.showsWelcome { browser.finishWelcome() }
        browser.openExternal(urls)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        browser?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// A fullscreen video takes the whole screen, as in Chrome: the window goes full screen (unless
    /// it already is), and the sidebar (RootView), toolbar and traffic lights hide.
    private func pageFullscreenChanged(_ fullscreen: Bool) {
        guard let window else { return }
        sidebarToggle?.isHidden = fullscreen
        // The titlebar holds the toolbar and the traffic lights. (SwiftUI's toolbar ignores being
        // hidden while it's bridged into the window.)
        window.standardWindowButton(.closeButton)?.superview?.superview?.isHidden = fullscreen
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if fullscreen, !isFullScreen {
            fullScreenForPage = true
            window.toggleFullScreen(nil)
        } else if !fullscreen, fullScreenForPage {
            fullScreenForPage = false
            if isFullScreen { window.toggleFullScreen(nil) }
        }
    }

    /// Full screen for a video: the toolbar's reveal strip goes away with the menu bar.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        fullScreenForPage ? proposed.union([.autoHideMenuBar, .autoHideToolbar]) : proposed
    }

    /// Leaving full screen (the green button, ⌃⌘F) brings the video back into the page too.
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenForPage = false
        browser?.pages.exitFullscreen()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        quit()
        return false
    }

    // MARK: - Menu actions

    private var store: BrowserStore? { browser?.store }
    private var selected: TabID? { store?.state.selectedTabID }

    @objc func newTab(_ sender: Any?) { browser?.newTab() }
    @objc func openLocation(_ sender: Any?) { browser?.presentCommandBar(.editCurrent) }

    @objc func closeTab(_ sender: Any?) {
        if browser?.commandBar.isPresented == true { return browser?.dismissCommandBar() ?? () }
        guard let id = selected else { return }
        withAnimation(.smooth(duration: 0.28)) { _ = store?.send(.closeTab(id)) }
    }

    @objc func reopenTab(_ sender: Any?) { store?.send(.reopenClosedTab) }
    @objc func reload(_ sender: Any?) { if let id = selected { store?.send(.reload(id)) } }
    @objc func hardReload(_ sender: Any?) { if let id = selected { store?.send(.hardReload(id)) } }
    @objc func stopLoading(_ sender: Any?) { if let id = selected { store?.send(.stop(id)) } }
    @objc func goBack(_ sender: Any?) { if let id = selected { store?.send(.goBack(id)) } }
    @objc func goForward(_ sender: Any?) { if let id = selected { store?.send(.goForward(id)) } }
    // ⌘← and ⌘→ as well, as in Safari. A page's text field takes them first, as do ours (see
    // validateMenuItem), where they move to the start or end of the line.
    @objc func checkForUpdates(_ sender: Any?) { updater?.checkForUpdates() }
    @objc func goBackWithArrow(_ sender: Any?) { goBack(sender) }
    @objc func goForwardWithArrow(_ sender: Any?) { goForward(sender) }
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
    @objc func duplicateSpace(_ sender: Any?) { browser?.duplicateSpace() }
    @objc func newSpace(_ sender: Any?) { browser?.newSpace() }
    @objc func customizeSpace(_ sender: Any?) {
        if let id = store?.state.activeSpaceID { browser?.customizeSpace(id) }
    }
    @objc func newFolder(_ sender: Any?) {
        withAnimation(.smooth(duration: 0.28)) { browser?.newFolder() }
    }
    @objc func developerTools(_ sender: Any?) { browser?.showDeveloperTools() }
    @objc func copyURL(_ sender: Any?) { browser?.copyLink() }
    @objc func boostSite(_ sender: Any?) { browser?.createBoostForCurrentSite() }
    @objc func showPackages(_ sender: Any?) { browser?.packages.revealInFinder() }
    @objc func copyAgentCommand(_ sender: Any?) { browser?.copyMCPCommand() }

    @objc func switchToSpace(_ sender: NSMenuItem) {
        guard let spaces = store?.state.spaces, spaces.indices.contains(sender.tag) else { return }
        store?.send(.switchSpace(spaces[sender.tag].id))
    }

    @objc func close(_ sender: Any?) { quit() }

    @objc func showSettings(_ sender: Any?) { browser?.openSettings() }
    @objc func showShortcuts(_ sender: Any?) { browser?.showShortcuts.toggle() }
    @objc func showWelcome(_ sender: Any?) { browser?.showsWelcome = true }
    @objc func showHistory(_ sender: Any?) { browser?.showHistory.toggle() }

    @objc func toggleSidebar(_ sender: Any?) {
        withAnimation { browser?.toggleSidebar() }
    }
    @objc func toggleFavorite(_ sender: Any?) { if let id = selected { store?.send(.toggleFavorite(id)) } }
    @objc func clearToday(_ sender: Any?) {
        withAnimation(.smooth(duration: 0.28)) { _ = store?.send(.clearToday) }
    }
    @objc func importFrom(_ sender: NSMenuItem) {
        if let source = (sender.representedObject as? String).flatMap(Browser.ImportSource.init(rawValue:)) {
            Task { await browser?.importBrowser(source) }
        }
    }
    @objc func importPasswordsCSV(_ sender: Any?) { browser?.openSettings("passwords") }
}

extension AppDelegate: NSMenuItemValidation {
    /// The arrow shortcuts step aside while you type in the address field or a sidebar name, so
    /// the field gets them. A disabled item's shortcut passes on to the field.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBackWithArrow(_:)), #selector(goForwardWithArrow(_:)):
            !(NSApp.keyWindow?.firstResponder is NSText)
        case #selector(checkForUpdates(_:)):
            updater?.canCheck ?? false
        default:
            true
        }
    }
}

/// Skylight's window. Escape belongs to pages and Skylight's own fields: one that nothing used
/// (a page passes on keys it doesn't handle) mustn't take the window out of full screen, which is
/// AppKit's default. A fullscreen video still leaves on Escape; the engine handles that first.
private final class BrowserWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {}
}
