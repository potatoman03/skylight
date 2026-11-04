import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// The whole window, laid out like Safari's: a source-list sidebar, the page, and one unified
/// toolbar with back and forward, the address field and extension buttons.
public struct RootView: View {
    @Environment(Browser.self) private var browser
    @State private var drag = TabDragSession()
    @State private var newName = ""

    public init() {}

    public var body: some View {
        let prefs = browser.preferences
        let state = browser.store.state

        NavigationSplitView(columnVisibility: Binding(
            get: { prefs.sidebarCollapsed ? .detailOnly : .all },
            set: { prefs.sidebarCollapsed = $0 == .detailOnly }
        )) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ContentArea()
                .toolbar { BrowserToolbar() }
                .toolbar(removing: .title)
        }
        .navigationTitle(state.selectedTab?.displayTitle ?? "Skylight")
        .environment(drag)
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
        }

        ToolbarItem(placement: .principal) {
            AddressField()
        }

        if browser.preferences.extensionPlacement.showsButtons, !browser.extensions.toolbar.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                PinnedExtensionButtons()
            }
        }

        ToolbarItem(placement: .primaryAction) {
            ExtensionsMenuButton()
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                browser.presentCommandBar(.newTab)
            } label: {
                Label("New Tab", systemImage: "plus")
            }
            .help("New Tab (⌘T)")
        }
    }
}
