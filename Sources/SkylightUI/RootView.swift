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

    private var showsSplit: Bool {
        let state = browser.store.state
        return state.selectedTabID.flatMap { state.activeSpace.split(containing: $0) }.map { $0.tabs.count > 1 } ?? false
    }

    public var body: some View {
        let prefs = browser.preferences
        let state = browser.store.state
        // A fullscreen video gets the whole window, which goes full screen with it.
        let fullscreen = browser.pages.fullscreenTabID != nil
        let space = state.activeSpace
        let accent = prefs.showsTheme(in: space) ? prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue).accent : nil
        let sidebarWidth = max(prefs.sidebarWidth, SidebarEdge.widths.lowerBound)
        let sidebarOnScreen = browser.showsSidebar && !fullscreen
        // A peeking sidebar lies over the page, which stays where it is.
        let beside = open && !fullscreen ? sidebarWidth : 0
        // A site can't lay itself out as fast as its edge moves, and what it draws arrives a few
        // frames behind the view, so resizing on the way would shake it. It moves as one piece,
        // and is resized once, where its right edge is out of sight. An empty page has no site.
        let rigid = !fitted && !browser.showsEmptyPage
        let sidebarRoom = rigid ? 0 : beside
        let emptyPage = state.selectedTab == nil
        let scene = prefs.showsScene(in: space, dark: scheme == .dark)

        // Our own sidebar column, flush with the page: the system's floating glass sidebar casts a
        // shadow on the page, and moves its toggle about.
        ZStack(alignment: .leading) {
            ContentArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Up under the hidden toolbar, edge to edge.
                .ignoresSafeArea(.container, edges: fullscreen ? .top : [])
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
                .overlay(alignment: .trailing) { SidebarEdge() }
                // It stays still while the page's edge crosses it, like a card sliding over it.
                .mask(alignment: .leading) {
                    Rectangle().frame(width: sliding && !open ? 0 : sidebarWidth).ignoresSafeArea()
                }
                .onHover { if browser.sidebarPeeking { peek($0) } }
                .offset(x: (open || sliding || browser.sidebarPeeking) && !fullscreen ? 0 : -sidebarWidth - 1)
                .allowsHitTesting(sidebarOnScreen)
                .accessibilityHidden(!sidebarOnScreen)
        }
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
        }
        // Plain icons, no capsules behind them.
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            AddressField()
        }
        .sharedBackgroundVisibility(.hidden)

        // On an extension's page in the Chrome Web Store, whose own button only works in Chrome.
        if let id = browser.store.state.selectedTab.flatMap({ WebStore.extensionID(from: $0.url.absoluteString) }), browser.extensions.isAvailable {
            ToolbarItem(placement: .primaryAction) {
                StoreAddButton(id: id)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        if browser.preferences.extensionPlacement.showsButtons, !browser.extensions.toolbar.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                PinnedExtensionButtons()
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItem(placement: .primaryAction) {
            ExtensionsMenuButton()
        }
        .sharedBackgroundVisibility(.hidden)
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
    @State private var start: Double?

    /// Wide enough that the toolbar's back, forward and reload buttons sit over the sidebar.
    static let widths = 220.0...420.0

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 16)
                    .contentShape(.rect)
                    .pointerStyle(.frameResize(position: .trailing))
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let prefs = browser.preferences
                            let from = start ?? prefs.sidebarWidth
                            start = from
                            prefs.sidebarWidth = min(max(from + drag.translation.width, Self.widths.lowerBound), Self.widths.upperBound).rounded()
                        }
                        .onEnded { _ in start = nil })
                    .ignoresSafeArea()
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
