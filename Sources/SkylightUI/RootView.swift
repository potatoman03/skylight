import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// The whole window, laid out like Safari's: a source-list sidebar, the page, and one unified
/// toolbar with back and forward, the address field and extension buttons.
public struct RootView: View {
    @Environment(Browser.self) private var browser
    @State private var drag = TabDragSession()
    @State private var anchor = AddressAnchor()
    @State private var newName = ""

    public init() {}

    public var body: some View {
        let prefs = browser.preferences
        let state = browser.store.state

        // Our own sidebar column, flush with the page: the system's floating glass sidebar casts a
        // shadow on the page, and moves its toggle about.
        HStack(spacing: 0) {
            if !prefs.sidebarCollapsed {
                Sidebar()
                    .frame(width: prefs.sidebarWidth)
                    .overlay(alignment: .trailing) { SidebarEdge() }
                    .transition(.move(edge: .leading))
            }
            ContentArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
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

        ToolbarItemGroup(placement: .navigation) {
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
        // Plain icons and text, no capsules behind them.
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            AddressField()
        }
        .sharedBackgroundVisibility(.hidden)

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

        ToolbarItem(placement: .primaryAction) {
            Button {
                browser.presentCommandBar(.newTab)
            } label: {
                Label("New Tab", systemImage: "plus")
            }
            .help("New Tab (⌘T)")
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// The sidebar's edge: a hairline you can drag to resize it, which remembers the width.
private struct SidebarEdge: View {
    @Environment(Browser.self) private var browser
    @State private var start: Double?

    static let widths = 200.0...420.0

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
