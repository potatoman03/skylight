import AppKit
import SkylightBrowser
import SkylightCore
import SkylightKit
import SwiftUI

/// The whole window, laid out like Safari's: a source-list sidebar, the page, and one unified
/// toolbar with back and forward, the address field and extension buttons.
public struct RootView: View {
    @Environment(Browser.self) private var browser
    @State private var drag = TabDragSession()
    @State private var anchor = AddressAnchor()
    @State private var newName = ""
    @State private var leaving: Task<Void, Never>?
    /// The page sits beside the sidebar.
    @State private var open = true
    /// The page is on its way over the sidebar or off it.
    @State private var sliding = false
    /// The page has been made to fit beside the sidebar. It's the window's width while it moves.
    @State private var fitted = true
    @State private var slide: Task<Void, Never>?
    @State private var backdropFrame = CGRect.zero
    @Environment(\.colorScheme) private var scheme

    public init() {}

    private struct SlideLayout: Equatable {
        let tab: TabID?
        let split: Bool
        let fullscreen: Bool
        let empty: Bool
        let sidebarWidth: CGFloat
    }

    private var showsSplit: Bool {
        let state = browser.store.state
        return state.selectedTabID.flatMap { state.activeSpace.split(containing: $0) }.map { $0.tabs.count > 1 } ?? false
    }

    /// Slides the page's left edge over the sidebar or off it, as Aside does: the sidebar stays
    /// where it is, the page lays out for each width on the way, and its right side stays still.
    private func slidePage(collapsed: Bool) {
        let prefs = browser.preferences
        let host = browser.pages.hostView
        let width = max(prefs.sidebarWidth, SidebarEdge.widths.lowerBound)
        slide = Task { @MainActor in
            // The resize divider is fixed at the sidebar's resting edge; hide it while the
            // page's edge moves, in both directions.
            withTransaction(Transaction(animation: nil)) { sliding = true }
            host.beginSlide(closing: collapsed, width: width, color: browser.pages.visiblePageColor)
            if !collapsed {
                withTransaction(Transaction(animation: nil)) { open = true }
            }
            await host.slideReady()
            guard !Task.isCancelled else { return }
            host.runSlide(seconds: Motion.sidebarSeconds, timing: Motion.sidebarTiming)
            try? await Task.sleep(for: Motion.sidebarTime)
            guard !Task.isCancelled else { return }
            if collapsed {
                let tab = browser.store.state.selectedTabID
                await host.waitForPaintedEdge {
                    guard let tab, browser.store.state.selectedTabID == tab else { return false }
                    return !browser.store.status(of: tab).isLoading
                }
            }
            guard !Task.isCancelled else { return }
            if collapsed { host.finishSlide(afterResize: true) }
            withTransaction(Transaction(animation: nil)) { open = !collapsed; sliding = false }
            if !collapsed { host.finishSlide(afterResize: false) }
        }
    }

    public var body: some View {
        let prefs = browser.preferences
        let state = browser.store.state
        // A fullscreen video gets the whole window, which goes full screen with it.
        let fullscreen = browser.pages.fullscreenTabID != nil
        let space = state.activeSpace
        let accent = prefs.showsTheme(in: space) ? prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue).accent : nil
        let sidebarWidth = max(prefs.sidebarWidth, SidebarEdge.widths.lowerBound)
        let slideLayout = SlideLayout(tab: state.selectedTabID, split: showsSplit, fullscreen: fullscreen,
                                      empty: browser.showsEmptyPage, sidebarWidth: sidebarWidth)
        let sidebarOnScreen = browser.showsSidebar && !fullscreen
        // A peeking sidebar lies over the page, which stays where it is.
        let beside = open && !fullscreen ? sidebarWidth : 0
        // A page alone reaches out of sight past its left edge by the sidebar's width, open or not.
        // A split's panes can't reach under the sidebar, so they move as one piece and are resized
        // once, where their right edge is out of sight.
        let rigid = !fitted && !browser.showsEmptyPage && showsSplit
        // What a page alone lays out beside. A split's panes ignore it, so it doesn't change with one.
        let covered = fullscreen ? 0 : sidebarWidth
        let sidebarRoom = rigid ? 0 : beside
        let emptyPage = state.selectedTab == nil
        let scene = prefs.showsScene(in: space, dark: scheme == .dark)
        // Under the welcome, only the backdrop shows; the rest comes up as it leaves.
        let welcome = browser.showsWelcome

        // Our own sidebar column, flush with the page: the system's floating glass sidebar casts a
        // shadow on the page, and moves its toggle about.
        let content = ZStack(alignment: .leading) {
            ContentArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Up under the hidden toolbar, edge to edge.
                .ignoresSafeArea(.container, edges: fullscreen ? .top : [])
                // A compact toolbar has a fixed height, so the bar's extra room comes out of the page.
                .padding(.top, fullscreen ? 0 : 4)
                // A split's rounded panes sit on the window's backdrop, like the sidebar. This never
                // fades: going to a Space with no tab, it would flash white over the theme's picture.
                .background {
                    if !showsSplit, !(emptyPage && scene) {
                        Rectangle().fill(.background).ignoresSafeArea().transition(.identity)
                    }
                }
                .padding(.leading, sidebarRoom)
                .offset(x: rigid ? beside : 0)
            // Off to the side when it's hidden, not gone, so it can peek straight back.
            Sidebar()
                .frame(width: sidebarWidth)
                // Without its room, it's over the page rather than the window's backdrop.
                .background { if !open, !sliding { SidebarGround() } }
                // It stays still while the page's edge crosses it, like a card sliding over it.
                .mask(alignment: .leading) {
                    Rectangle().frame(width: sliding && !open ? 0 : sidebarWidth).ignoresSafeArea()
                }
                .onHover { if browser.sidebarPeeking { peek($0) } }
                .offset(x: (open || sliding || browser.sidebarPeeking) && !fullscreen ? 0 : -sidebarWidth - 1)
                .allowsHitTesting(sidebarOnScreen)
                .accessibilityHidden(!sidebarOnScreen)
                // Let the page cover the sidebar only while its edge crosses it. At rest the
                // sidebar must be above the page's transparent new-tab overlay for clicks.
                .zIndex(!sliding || browser.sidebarPeeking || drag.active != nil ? 1 : -1)
                .offset(x: welcome && !Motion.reduceMotion ? -16 : 0)
            // Above the page, which it reaches over.
            SidebarEdge()
                .opacity(sliding ? 0 : 1)
                .frame(width: sidebarWidth, alignment: .trailing)
                .offset(x: (open || browser.sidebarPeeking) && !fullscreen ? 0 : -sidebarWidth - 1)
                .allowsHitTesting(sidebarOnScreen && !sliding)
                .zIndex(2)
        }
        .opacity(welcome ? 0 : 1)
        .allowsHitTesting(!welcome)
        .animation(Motion.resolved(.smooth(duration: 0.9)), value: welcome)
        // With the sidebar hidden, the pointer at the window's left edge brings it out, just as
        // showing it does, until the pointer leaves it. A thin strip leaves the page's edge usable.
        .overlay(alignment: .leading) {
            if !browser.showsSidebar, !fullscreen {
                Color.clear
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .onHover { if $0 { peek(true) } }
            }
        }
        .overlay { SkylightMenu() }
        // The menu opens from the sidebar, so a peeking sidebar stays until it closes.
        .onChange(of: browser.showsMainMenu) { _, open in if !open, browser.sidebarPeeking { peek(false) } }
        // Showing or hiding it for good ends the peek.
        .onChange(of: prefs.sidebarCollapsed) { _, collapsed in
            leaving?.cancel()
            slide?.cancel()
            if !Motion.reduceMotion, !showsSplit, !browser.showsEmptyPage, !fullscreen {
                slidePage(collapsed: collapsed)
                return
            }
            // Everything in place first, so the move starts from there.
            withTransaction(Transaction(animation: nil)) {
                sliding = true
                fitted = false
            }
            slide = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1))
                guard !Task.isCancelled else { return }
                animate(Motion.sidebar) { open = !collapsed }
                try? await Task.sleep(for: Motion.sidebarTime)
                guard !Task.isCancelled else { return }
                withTransaction(Transaction(animation: nil)) {
                    sliding = false
                    fitted = true
                }
            }
        }
        .onAppear { open = !prefs.sidebarCollapsed }
        .onChange(of: slideLayout) { _, _ in
            guard sliding else { return }
            slide?.cancel()
            browser.pages.hostView.cancelSlide()
            withTransaction(Transaction(animation: nil)) {
                open = !prefs.sidebarCollapsed
                sliding = false
                fitted = true
            }
        }
        .onChange(of: covered, initial: true) { _, width in browser.pages.setCovered(width) }
        // Keep the window modifiers separate so Swift can type-check the view.
        content
        // One backdrop behind the toolbar and sidebar, translucent or the theme's; only the page is opaque.
        .background {
            WindowBackdrop().ignoresSafeArea()
            if prefs.showsTheme(in: space) {
                ThemeBackdrop()
                    .ignoresSafeArea()
                    .transition(.identity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { backdropFrame = $0 }
            }
        }
        .environment(\.backdropFrame, backdropFrame)
        .tint(accent.map { Color($0) })
        .environment(\.onTint, accent.map { Color($0.ink) } ?? .white)
        .toolbar { BrowserToolbar() }
        .toolbar(removing: .title)
        // The sidebar runs up behind the traffic lights; the page keeps the window's own background.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(state.selectedTab?.displayTitle ?? "Skylight")
        .environment(drag)
        .environment(anchor)
        .frame(minWidth: 760, minHeight: 480)
        // The Space on screen renames in place in its header; others (from the Space bar) here.
        .alert("Rename Space", isPresented: Binding(get: { browser.renameSpace.map { $0 != state.activeSpaceID } ?? false },
                                                     set: { if !$0 { browser.renameSpace = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let id = browser.renameSpace { browser.store.send(.renameSpace(id, newName)) }
                browser.renameSpace = nil
            }
            Button("Cancel", role: .cancel) { browser.renameSpace = nil }
        }
        .sheet(isPresented: Binding(get: { browser.showShortcuts }, set: { browser.showShortcuts = $0 })) {
            ShortcutsSheet()
        }
        .modifier(WelcomeHost())
        .sheet(item: Binding(get: { browser.spaceSetup }, set: { browser.spaceSetup = $0 })) {
            SpaceSetupSheet(request: $0)
        }
        .onChange(of: browser.renameSpace) { _, id in
            newName = state.spaces.first { $0.id == id }?.name ?? ""
        }
    }

    /// The pointer reached the edge strip or the peeking sidebar (`inside`), or left the sidebar.
    /// The sidebar goes a moment after the pointer leaves, so overshooting doesn't close it, and
    /// after a longer moment if the pointer never reaches it.
    private func peek(_ inside: Bool) {
        leaving?.cancel()
        let opening = inside && !browser.sidebarPeeking
        if opening { animate(Motion.sidebar) { browser.sidebarPeeking = true } }
        guard !inside || opening else { return }
        leaving = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(opening ? 1500 : 300))
            if !Task.isCancelled, !browser.showsMainMenu { animate(Motion.sidebar) { browser.sidebarPeeking = false } }
        }
    }
}

private struct BrowserToolbar: ToolbarContent {
    @Environment(Browser.self) private var browser

    var body: some ToolbarContent {
        let status = browser.selectedStatus
        let id = browser.store.state.selectedTabID

        // One compact group, so Reload keeps clear of the sidebar's edge.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 2) {
                Button {
                    if let id { browser.store.send(.goBack(id)) }
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .help("Back")
                .disabled(!status.canGoBack)
                Button {
                    if let id { browser.store.send(.goForward(id)) }
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .help("Forward")
                .disabled(!status.canGoForward)
                Button {
                    if let id { browser.store.send(status.isLoading ? .stop(id) : .reload(id)) }
                } label: {
                    Label(status.isLoading ? "Stop" : "Reload", systemImage: status.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(status.isLoading ? "Stop Loading (⌘.)" : "Reload Page (⌘R)")
                .disabled(id == nil)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ToolbarIconStyle())
            .modifier(HiddenByWelcome())
        }
        // Plain icons, no capsules behind them.
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            AddressField().modifier(HiddenByWelcome())
        }
        .sharedBackgroundVisibility(.hidden)

        // On an extension's page in the Chrome Web Store, whose own button only works in Chrome.
        if let id = browser.store.state.selectedTab.flatMap({ WebStore.extensionID(from: $0.url.absoluteString) }), browser.extensions.isAvailable {
            ToolbarItem(placement: .primaryAction) {
                StoreAddButton(id: id).modifier(HiddenByWelcome())
            }
            .sharedBackgroundVisibility(.hidden)
        }

        if browser.preferences.extensionPlacement.showsButtons, !browser.extensions.toolbar.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                PinnedExtensionButtons().modifier(HiddenByWelcome())
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItem(placement: .primaryAction) {
            ExtensionsMenuButton().modifier(HiddenByWelcome())
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// The toolbar's controls wait while the welcome is up, and come back with the sidebar.
private struct HiddenByWelcome: ViewModifier {
    @Environment(Browser.self) private var browser

    func body(content: Content) -> some View {
        content
            .opacity(browser.showsWelcome ? 0 : 1)
            .allowsHitTesting(!browser.showsWelcome)
            .animation(Motion.resolved(.smooth(duration: 0.9)), value: browser.showsWelcome)
    }
}

/// What the window's backdrop would show, for a sidebar peeking over a page.
private struct SidebarGround: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let prefs = browser.preferences
        let space = browser.store.state.activeSpace
        Group {
            if prefs.showsTheme(in: space) {
                let palette = prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue)
                LinearGradient(colors: [Color(palette.sky), Color(palette.horizon)], startPoint: .top, endPoint: .bottom)
            } else {
                WindowBackdrop()
            }
        }
        .ignoresSafeArea()
    }
}

/// The sidebar's edge: a hairline you can drag to resize it, which remembers the width.
struct SidebarEdge: View {
    @Environment(Browser.self) private var browser
    /// The width when the drag began. This clears itself however a drag ends, even with no
    /// mouse-up, so the next one can't start from an old width and jump.
    @GestureState private var start: Double?

    /// Allows a compact sidebar while leaving room for its icon-only header controls.
    static let widths = 150.0...420.0

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 16)
                    .contentShape(.rect)
                    .pointerStyle(.frameResize(position: .trailing))
                    // A click that wobbles isn't a drag.
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .updating($start) { drag, start, _ in
                            let prefs = browser.preferences
                            let from = start ?? prefs.sidebarWidth
                            start = from
                            prefs.resizingSidebar = true
                            prefs.sidebarWidth = min(max(from + drag.translation.width, Self.widths.lowerBound), Self.widths.upperBound)
                        })
                    .ignoresSafeArea()
            }
            .onChange(of: start == nil) { _, ended in
                if ended { browser.preferences.resizingSidebar = false }
            }
    }
}

/// A toolbar icon with a box that shows on hover and dips when pressed, like the sidebar button.
struct ToolbarIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }

    private struct Look: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .background(.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(Motion.resolved(Motion.feedback), value: configuration.isPressed)
                .animation(Motion.resolved(Motion.feedback), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// The sidebar button, hosted beside the traffic lights as a titlebar accessory so it never moves,
/// whether the sidebar is open or not.
public struct SidebarToggle: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    public init() {}

    public var body: some View {
        let collapsed = browser.preferences.sidebarCollapsed
        Button {
            withAnimation { browser.toggleSidebar() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .background(.primary.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(collapsed ? "Show Sidebar (⌘S)" : "Hide Sidebar (⌘S)")
        .accessibilityLabel(collapsed ? "Show Sidebar" : "Hide Sidebar")
        .padding(.leading, 4)
        .frame(maxHeight: .infinity)
    }
}
