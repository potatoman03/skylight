import SkylightAgent
import SkylightBrowser
import SkylightCore
import SwiftUI

/// SwiftUI has its own `Tab`.
typealias BrowserTab = SkylightCore.Tab

/// Arc's layout: favorites shared by every Space at the top, then the Space's pinned tabs, a
/// line, and today's tabs. Spaces switch at the bottom. The window controls above it belong to
/// `RootView`, so they stay put when the sidebar hides.
struct Sidebar: View {
    let omnibox: Namespace.ID
    /// Room left at the top for the window controls.
    var topInset: CGFloat = 40
    @Environment(Browser.self) private var browser
    @Namespace private var selection
    @State private var hovering = false

    var body: some View {
        let state = browser.store.state
        let space = state.activeSpace

        let prefs = browser.preferences
        VStack(alignment: .leading, spacing: 10) {
            if prefs.shows(.addressBar) { URLPill(omnibox: omnibox).transition(.opacity) }

            if prefs.shows(.favorites) { FavoritesGrid(selection: selection).transition(.opacity) }

            // The Space's tabs swap as one body: a crossfade with a small rise, never a slide.
            VStack(alignment: .leading, spacing: 4) {
                SpaceHeader(space: space, revealed: hovering)
                SpaceTabs(space: space, selection: selection)
            }
            .id(space.id)
            .transition(Arrive(scale: 1, rise: 8))
            .motion(Motion.swap, value: space.id)
            .onHover { h in animate(Motion.feedback) { hovering = h } }

            if prefs.shows(.agentActivity) { AgentActivityBadge() }
            BottomBar()
        }
        .padding(.horizontal, 10)
        .padding(.top, topInset)
        .padding(.bottom, 8)
    }
}

// MARK: - Controls

/// Back, forward and reload, beside the sidebar toggle. Lives in `RootView`'s fixed top row.
struct NavigationButtons: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let status = browser.selectedStatus
        let id = browser.store.state.selectedTabID
        HStack(spacing: 1) {
            IconButton(symbol: "arrow.left", help: "Back (⌘[)", enabled: status.canGoBack) {
                if let id { browser.store.send(.goBack(id)) }
            }
            IconButton(symbol: "arrow.right", help: "Forward (⌘])", enabled: status.canGoForward) {
                if let id { browser.store.send(.goForward(id)) }
            }
            IconButton(symbol: status.isLoading ? "xmark" : "arrow.clockwise", help: status.isLoading ? "Stop" : "Reload (⌘R)",
                       enabled: id != nil && browser.store.state.selectedTab?.url.isSkylightPage == false) {
                guard let id else { return }
                browser.store.send(status.isLoading ? .stop(id) : .reload(id))
            }
            .contentTransition(.symbolEffect(.replace))
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 28)
                .surface(hovering && enabled ? .hover : nil, radius: 8)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .disabled(!enabled)
        .help(help)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
    }
}

/// The selected tab's address. Clicking it grows it into the command bar.
private struct URLPill: View {
    let omnibox: Namespace.ID
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let tab = browser.store.state.selectedTab
        let presented = browser.commandBar.isPresented
        ZStack {
            if !presented {
                HStack(spacing: 7) {
                    if tab?.url.scheme == "https" {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    } else if tab == nil {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    Text(tab.map(Self.display) ?? "Search or enter address")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tab == nil ? HierarchicalShapeStyle.tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    LoginKeyButton(url: tab?.url)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .surface(hovering ? .selected : .field, radius: 11, lifted: true)
                .matchedGeometryEffect(id: "omnibox", in: omnibox)
                .transition(.opacity)
            } else {
                Color.clear.frame(height: 34)
            }
        }
        .contentShape(.rect)
        .onTapGesture { browser.presentCommandBar(.editCurrent) }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
    }

    static func display(_ tab: BrowserTab) -> String {
        if tab.url.isSkylightPage { return tab.displayTitle }
        guard let host = tab.url.host(percentEncoded: false) else { return tab.url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Favorites

/// Favorites belong to no Space: they stay put when you switch.
private struct FavoritesGrid: View {
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        let tabs = state.favoriteTabs
        if !tabs.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: tabs.count < 4 ? max(tabs.count, 3) : 4),
                      spacing: 7) {
                ForEach(tabs) { tab in
                    FavoriteTile(tab: tab, selected: state.selectedTabID == tab.id, selection: selection)
                        .transition(Arrive(scale: 0.85))
                }
            }
            .motion(Motion.travel, value: state.favorites)
            .dropDestination(for: String.self) { ids, _ in
                drop(ids) { id in
                    if !state.isFavorite(id) { browser.store.send(.toggleFavorite(id)) }
                }
            }
        }
    }

    private func drop(_ ids: [String], _ perform: (TabID) -> Void) -> Bool {
        guard let raw = ids.first else { return false }
        animate(Motion.travel) { perform(TabID(raw)) }
        return true
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    let selected: Bool
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let awake = browser.store.status(of: tab.id).isAwake
        Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: 20)
            .opacity(awake || selected ? 1 : 0.85)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                if selected {
                    Color.clear.surface(.selected, radius: 12, lifted: true)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else {
                    Color.clear.surface(hovering ? .selected : .resting, radius: 12, lifted: true)
                }
            }
            .contentShape(.rect)
            .onTapGesture { animate(Motion.travel) { _ = browser.store.send(.selectTab(tab.id)) } }
            .onHover { h in animate(Motion.feedback) { hovering = h } }
            .help(tab.displayTitle)
            .draggable(tab.id.rawValue)
            .contextMenu { TabMenu(tab: tab) }
    }
}

// MARK: - The Space

/// The Space's name, its profile (only when it isn't the default) and, on hover, Clear and the menu.
private struct SpaceHeader: View {
    let space: Space
    let revealed: Bool
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @State private var clearHovering = false

    var body: some View {
        let state = browser.store.state
        let profile = state.profile(space.profileID)
        HStack(spacing: 8) {
            SpaceIcon(icon: space.icon, name: space.name, size: 11)
                .foregroundStyle(Theme.accent(space.hue, scheme))
                .frame(width: 20, height: 20)
                .background(Theme.accent(space.hue, scheme).opacity(0.14), in: .rect(cornerRadius: 6, style: .continuous))
            Text(space.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(1)
            if let profile, space.profileID != .standard || profile.icon != nil || profile.hue != nil {
                ProfileBadge(profile: profile)
                    .help("Profile: \(profile.name)")
            }
            Spacer(minLength: 0)
            Group {
                if !space.today.isEmpty {
                    Button {
                        animate(Motion.travel) { _ = browser.store.send(.clearToday) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold))
                            Text("Clear").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(clearHovering ? .secondary : .tertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .surface(clearHovering ? .hover : nil, radius: 6)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in animate(Motion.feedback) { clearHovering = h } }
                    .help("Close today's tabs, except this one (⌘⇧K)")
                }
                Menu {
                    SpaceMenu(space: space)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(.tertiary)
                .fixedSize()
            }
            .opacity(revealed ? 1 : 0)
        }
        .padding(.leading, 6)
        .padding(.vertical, 2)
        .contextMenu { SpaceMenu(space: space) }
    }
}

private struct SpaceTabs: View {
    let space: Space
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        let pinned = state.tabs(in: space, .pinned)
        let today = state.tabs(in: space, .today)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                // Pinned. With none, a thin strip still takes drops.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pinned) { tab in
                        TabRow(tab: tab, pinned: true, selected: space.selectedTabID == tab.id, selection: selection)
                            .transition(Arrive(anchor: .top, scale: 0.98))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 6, alignment: .top)
                .contentShape(.rect)
                .dropDestination(for: String.self) { ids, _ in move(ids, to: .pinned, at: space.pinned.count) }

                if !pinned.isEmpty {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if browser.preferences.shows(.newTab) { NewTabRow() }
                    ForEach(today) { tab in
                        TabRow(tab: tab, pinned: false, selected: space.selectedTabID == tab.id, selection: selection)
                            .transition(Arrive(anchor: .top, scale: 0.98))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .contentShape(.rect)
                .dropDestination(for: String.self) { ids, _ in move(ids, to: .today, at: 0) }
            }
            .motion(Motion.travel, value: space.pinned)
            .motion(Motion.travel, value: space.today)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func move(_ ids: [String], to section: SkylightCore.TabSection, at index: Int) -> Bool {
        guard let raw = ids.first else { return false }
        animate(Motion.travel) { _ = browser.store.send(.moveTab(TabID(raw), to: section, index: index)) }
        return true
    }
}

private struct NewTabRow: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 16)
            Text("New Tab").font(.system(size: 13))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: browser.preferences.density.rowHeight - 2)
        .surface(hovering ? .hover : nil)
        .contentShape(.rect)
        .onTapGesture { browser.presentCommandBar(.newTab) }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let pinned: Bool
    let selected: Bool
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let status = browser.store.status(of: tab.id)
        HStack(spacing: 9) {
            ZStack {
                if status.isLoading {
                    ProgressView().controlSize(.mini).transition(.opacity)
                } else {
                    Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle).transition(.opacity)
                }
            }
            .frame(width: 16, height: 16)
            .opacity(pinned && !status.isAwake && !selected ? 0.7 : 1)
            .motion(Motion.feedback, value: status.isLoading)

            Text(tab.displayTitle)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(status.isAwake || selected ? HierarchicalShapeStyle.primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button {
                    animate(Motion.travel) { _ = browser.store.send(.closeTab(tab.id)) }
                } label: {
                    // A pinned tab's button only unloads it, as in Arc.
                    Image(systemName: pinned ? "minus" : "xmark").font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 20)
                        .surface(.hover, radius: 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .help(pinned ? "Unload tab (⌘W)" : "Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: browser.preferences.density.rowHeight)
        .background {
            if selected {
                Color.clear.surface(.selected, lifted: true)
                    .matchedGeometryEffect(id: "selection", in: selection)
            } else if hovering {
                Color.clear.surface(.hover)
            }
        }
        .contentShape(.rect)
        .onTapGesture { animate(Motion.travel) { _ = browser.store.send(.selectTab(tab.id)) } }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .draggable(tab.id.rawValue) {
            HStack(spacing: 8) {
                Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle)
                Text(tab.displayTitle).font(.system(size: 13)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 34, alignment: .leading)
            .surface(.selected)
        }
        .contextMenu { TabMenu(tab: tab) }
    }
}

private struct TabMenu: View {
    let tab: BrowserTab
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        let favorite = state.isFavorite(tab.id)
        let pinned = state.space(containing: tab.id)?.section(of: tab.id) == .pinned
        Button(favorite ? "Remove from Favorites" : "Add to Favorites") {
            animate(Motion.travel) { _ = browser.store.send(.toggleFavorite(tab.id)) }
        }
        if !favorite {
            Button(pinned ? "Unpin" : "Pin") { animate(Motion.travel) { _ = browser.store.send(.togglePin(tab.id)) } }
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
        }
        if !favorite {
            Menu("Move to Space") {
                ForEach(state.spaces.filter { !$0.contains(tab.id) }) { space in
                    Button(space.name) { animate(Motion.travel) { _ = browser.store.send(.moveTabToSpace(tab.id, space.id)) } }
                }
            }
        }
        Divider()
        if favorite || pinned {
            Button("Unload") { animate(Motion.travel) { _ = browser.store.send(.closeTab(tab.id)) } }
            Button("Delete", role: .destructive) { animate(Motion.travel) { _ = browser.store.send(.removeTab(tab.id)) } }
        } else {
            Button("Close Tab") { animate(Motion.travel) { _ = browser.store.send(.closeTab(tab.id)) } }
        }
    }
}

/// Rename, icon, profile, delete: the same menu on the header and the switcher.
struct SpaceMenu: View {
    let space: Space
    @Environment(Browser.self) private var browser

    static let icons = ["sun.max", "moon", "briefcase", "house", "book", "star", "heart", "leaf", "bolt", "flame",
                        "globe.americas", "music.note", "graduationcap", "cart", "paintpalette",
                        "chevron.left.forwardslash.chevron.right"]

    var body: some View {
        let state = browser.store.state
        Button("Rename…") { browser.renameSpace = space.id }
        Menu("Icon") {
            ForEach(Self.icons, id: \.self) { icon in
                Button { browser.store.send(.setSpaceIcon(space.id, icon)) } label: { Label(icon, systemImage: icon) }
            }
            Divider()
            Button("None") { browser.store.send(.setSpaceIcon(space.id, nil)) }
        }
        Menu("Profile") {
            ForEach(state.profiles) { profile in
                Toggle(profile.name, isOn: Binding(get: { space.profileID == profile.id },
                                                   set: { if $0 { browser.store.send(.assignProfile(space.id, profile.id)) } }))
            }
            Divider()
            Button("Manage Profiles…") { browser.openSettings("profiles") }
        }
        Menu("Theme") {
            Toggle("Same as the app", isOn: Binding(get: { space.themeID == nil },
                                                    set: { if $0 { animate(Motion.swap) { _ = browser.store.send(.setSpaceTheme(space.id, nil)) } } }))
            Divider()
            ForEach(browser.preferences.themes) { theme in
                Toggle(theme.name, isOn: Binding(get: { space.themeID == theme.id },
                                                 set: { if $0 { animate(Motion.swap) { _ = browser.store.send(.setSpaceTheme(space.id, theme.id)) } } }))
            }
            Divider()
            Button("Appearance…") { browser.openSettings("appearance") }
        }
        Button("Space Settings…") { browser.openSettings("spaces") }
        if state.spaces.count > 1 {
            Divider()
            Button("Delete Space", role: .destructive) { animate(Motion.swap) { _ = browser.store.send(.deleteSpace(space.id)) } }
        }
    }
}

// MARK: - Bottom

private struct BottomBar: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @State private var newName = ""
    @State private var themes = false

    var body: some View {
        @Bindable var browser = browser
        let state = browser.store.state
        HStack(spacing: 2) {
            IconButton(symbol: "gearshape", help: "Settings (⌘,)") { browser.openSettings() }
            IconButton(symbol: "paintbrush", help: "Theme") { themes.toggle() }
                .popover(isPresented: $themes, arrowEdge: .top) { QuickThemePanel() }
            Spacer(minLength: 4)
            ForEach(state.spaces) { space in
                let active = space.id == state.activeSpaceID
                Button { animate(Motion.swap) { _ = browser.store.send(.switchSpace(space.id)) } } label: {
                    SpaceIcon(icon: space.icon, name: space.name, size: 12)
                        .foregroundStyle(active ? AnyShapeStyle(Theme.accent(space.hue, scheme)) : AnyShapeStyle(.tertiary))
                        .frame(width: 26, height: 26)
                        .surface(active ? .selected : nil, radius: 8, lifted: active)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(space.name)
                .contextMenu { SpaceMenu(space: space) }
            }
            .motion(Motion.travel, value: state.activeSpaceID)
            Spacer(minLength: 4)
            IconButton(symbol: "plus", help: "New Space (⌘⇧N)") {
                animate(Motion.swap) { _ = browser.store.send(.createSpace(name: "Space \(state.spaces.count + 1)")) }
            }
        }
        .alert("Rename Space", isPresented: Binding(get: { browser.renameSpace != nil }, set: { if !$0 { browser.renameSpace = nil } })) {
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

/// Shows the latest agent action for a few seconds.
private struct AgentActivityBadge: View {
    @Environment(Browser.self) private var browser
    @State private var visible: AgentActivity?

    var body: some View {
        ZStack {
            if let activity = visible {
                HStack(spacing: 7) {
                    Image(systemName: activity.succeeded ? "sparkles" : "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolEffect(.pulse, isActive: activity.succeeded)
                    Text("\(activity.client) · \(activity.tool.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .surface(.field, radius: 14)
                .transition(Arrive(anchor: .bottom, scale: 0.94, rise: 6))
            }
        }
        .task(id: browser.agents.activity.first?.id) {
            guard let latest = browser.agents.activity.first, Date.now.timeIntervalSince(latest.date) < 5 else { return }
            animate(Motion.arrive) { visible = latest }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            animate(Motion.exit) { visible = nil }
        }
    }
}
