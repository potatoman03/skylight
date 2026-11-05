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

        // Our own sidebar column, flush with the page: the system's floating glass sidebar casts a
        // shadow on the page, and moves its toggle about.
        HStack(spacing: 0) {
            if !prefs.sidebarCollapsed, !fullscreen {
                Sidebar()
                    .frame(width: max(prefs.sidebarWidth, SidebarEdge.widths.lowerBound))
                    .overlay(alignment: .trailing) { SidebarEdge() }
                    .transition(.move(edge: .leading))
            }
            ContentArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Up under the hidden toolbar, edge to edge.
                .ignoresSafeArea(.container, edges: fullscreen ? .top : [])
                // A split's rounded panes sit on the window's backdrop, like the sidebar.
                .background(showsSplit ? AnyShapeStyle(.clear) : AnyShapeStyle(.background))
        }
        // Over the page and the toolbar's backdrop, as the sidebar itself sits.
        .overlay(alignment: .leading) {
            if prefs.sidebarCollapsed, !fullscreen { SidebarPeek() }
        }
        // One translucent backdrop behind the toolbar and sidebar; only the page is opaque.
        .background { WindowBackdrop().ignoresSafeArea() }
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
        .onChange(of: browser.renameSpace) { _, id in
            newName = state.spaces.first { $0.id == id }?.name ?? ""
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

        // Extension buttons keep to the window's right edge, however wide it is.
        ToolbarSpacer(.flexible)

        // On an extension's page in the Chrome Web Store, whose own button only works in Chrome.
        // Not over a new tab's empty page, which isn't the store.
        if let id = browser.store.state.selectedTab.flatMap({ WebStore.extensionID(from: $0.url.absoluteString) }), browser.extensions.isAvailable,
           !(browser.commandBar.isPresented && browser.commandBar.mode == .newTab) {
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
                    .frame(width: 9)
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

/// With the sidebar hidden, the pointer at the window's left edge slides the sidebar out over the
/// page. It stays while the pointer is over it and goes a moment after the pointer leaves.
struct SidebarPeek: View {
    @Environment(Browser.self) private var browser
    @State private var shown = false
    @State private var leaving: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .leading) {
            // A thin strip along the edge: little enough to leave the page's own edge usable.
            Color.clear
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .onHover { if $0 { show(true) } }
            if shown {
                // The sidebar itself, sliding out over the page as it does when you show it, and
                // running up behind the traffic lights.
                Sidebar()
                    .frame(width: max(browser.preferences.sidebarWidth, SidebarEdge.widths.lowerBound))
                    .frame(maxHeight: .infinity)
                    .background { WindowBackdrop().ignoresSafeArea() }
                    .shadow(color: .black.opacity(0.18), radius: 14, x: 2)
                    .onHover { show($0) }
                    .transition(.move(edge: .leading))
            }
        }
        .motion(.default, value: shown)
        // Showing the sidebar for good takes the peek with it.
        .onDisappear { leaving?.cancel() }
    }

    private func show(_ inside: Bool) {
        leaving?.cancel()
        if inside {
            shown = true
        } else {
            // A short grace, so crossing the gap at the edge or overshooting doesn't close it.
            leaving = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { shown = false }
            }
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
