import SkylightAgent
import SkylightBrowser
import SkylightCore
import SwiftUI

/// SwiftUI has its own `Tab`.
typealias BrowserTab = SkylightCore.Tab

/// What a sidebar row stands for: a tab, or a split (one row for all its panes).
enum SidebarRow: Hashable {
    case tab(TabID)
    case split(String)
}

/// A source list, like Finder's or Mail's: favorites shared by every Space, then the Space's pinned
/// tabs and today's tabs. Spaces switch from the bar at the bottom.
struct Sidebar: View {
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let state = browser.store.state
        let space = state.activeSpace
        let prefs = browser.preferences

        List(selection: selection) {
            // Favorites sit on top as a grid of tiles, as in Arc, shared by every Space.
            if prefs.shows(.favorites), !state.favorites.isEmpty || drag.active != nil {
                FavoritesGrid(tabs: state.favoriteTabs, selected: state.selectedTabID)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }

            Section {
                rows(space, .pinned)
                if space.pinned.isEmpty {
                    DropHint(text: "Drag tabs here to pin them", target: .section(.pinned, row: 0))
                }
            } header: {
                SpaceHeader(space: space)
            }

            Section {
                if prefs.shows(.newTab) { NewTabRow() }
                rows(space, .today)
            } header: {
                TodayHeader(space: space)
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, prefs.density.rowSize)
        .scrollContentBackground(prefs.skyBackdrop ? .hidden : .automatic)
        .background {
            if prefs.skyBackdrop {
                let palette = prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue)
                SkyBackdrop(palette: palette, rays: prefs.godRays).ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if prefs.shows(.agentActivity) { AgentActivityBadge() }
                SpaceBar()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        // A different Space is a different list: crossfade rather than morph one into the other.
        .id(space.id)
        .transition(.opacity)
    }

    /// One section's rows: a row per tab, one per split.
    @ViewBuilder
    private func rows(_ space: Space, _ section: SkylightCore.TabSection) -> some View {
        let state = browser.store.state
        ForEach(SidebarRows.make(space[section], space: space), id: \.self) { row in
            if row.count > 1, let split = space.split(containing: row[0]) {
                SplitRow(split: split).tag(SidebarRow.split(split.id))
            } else if let tab = state.tabs[row[0]] {
                TabRow(tab: tab, kind: section == .pinned ? .pinned : .today).tag(SidebarRow.tab(tab.id))
            }
        }
        .dropDestination(for: String.self) { items, index in browser.drop(items, on: .section(section, row: index)) }
    }

    /// The list's selection is the selected tab, or the split showing it.
    private var selection: Binding<SidebarRow?> {
        Binding {
            let state = browser.store.state
            guard let id = state.selectedTabID else { return nil }
            return state.activeSpace.split(containing: id).map { .split($0.id) } ?? .tab(id)
        } set: { row in
            let state = browser.store.state
            switch row {
            case let .tab(id)?:
                if id != state.selectedTabID { browser.store.send(.selectTab(id)) }
            case let .split(id)?:
                // Keep the focused pane if it's already in this split.
                guard let split = state.activeSpace.splits.first(where: { $0.id == id }),
                      !split.tabs.contains(where: { $0 == state.selectedTabID }) else { return }
                browser.store.send(.selectTab(split.tabs[0]))
            case nil:
                break
            }
        }
    }
}

/// Favorites as tiles: the site's icon on a rounded square, the open one highlighted. Drop a tab
/// on a tile to put it before that one, or in the gap after the last.
private struct FavoritesGrid: View {
    let tabs: [BrowserTab]
    let selected: TabID?
    @Environment(Browser.self) private var browser

    var body: some View {
        if tabs.isEmpty {
            Text("Drop a tab here to keep it in every Space")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                .dropDestination(for: String.self) { items, _ in browser.drop(items, on: .favorites(index: 0)) }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 80), spacing: 8)], spacing: 8) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    FavoriteTile(tab: tab, selected: tab.id == selected)
                        .dropDestination(for: String.self) { items, _ in browser.drop(items, on: .favorites(index: index)) }
                }
            }
            .padding(.vertical, 2)
            // Dropping below the tiles adds to the end.
            .dropDestination(for: String.self) { items, _ in browser.drop(items, on: .favorites(index: tabs.count)) }
        }
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    let selected: Bool
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @State private var hovering = false

    var body: some View {
        let status = browser.store.status(of: tab.id)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0.6)))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
            if status.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: 20)
            }
        }
        .frame(height: 44)
        .overlay(alignment: .topTrailing) {
            MediaBadge(tab: tab.id).padding(2)
        }
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { browser.store.send(.selectTab(tab.id)) }
        .onHover { hovering = $0 }
        .help(tab.displayTitle)
        .contextMenu { TabMenu(tab: tab) }
        .tabDrag(tab, source: .row, session: drag)
        .accessibilityElement()
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// An empty section's row: says what it's for and takes drops.
private struct DropHint: View {
    let text: String
    let target: TabDropTarget
    @Environment(Browser.self) private var browser

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .selectionDisabled()
            .dropDestination(for: String.self) { items, _ in browser.drop(items, on: target) }
    }
}

// MARK: - Headers

/// The Space's name (click it to rename) and profile, with its menu.
private struct SpaceHeader: View {
    let space: Space
    @Environment(Browser.self) private var browser
    @State private var editing = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let profile = browser.store.state.profile(space.profileID)
        HStack(spacing: 6) {
            if editing {
                TextField("Space name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(space.name)
                    .contentShape(.rect)
                    .onTapGesture(perform: startEditing)
                    .help("Click to rename")
            }
            if let profile, space.profileID != .standard, !editing {
                Text(profile.name)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                    .help("Profile: \(profile.name)")
            }
            Spacer(minLength: 4)
            Menu {
                SpaceMenu(space: space)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Space options")
        }
        .contextMenu { SpaceMenu(space: space) }
        .onChange(of: browser.renameSpace) { _, id in
            // Renaming the Space on screen happens right here, not in an alert.
            if id == space.id {
                browser.renameSpace = nil
                startEditing()
            }
        }
    }

    private func startEditing() {
        name = space.name
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != space.name { browser.store.send(.renameSpace(space.id, trimmed)) }
    }
}

private struct TodayHeader: View {
    let space: Space
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 6) {
            Text("Today")
            Spacer(minLength: 4)
            if !space.today.isEmpty {
                Button("Clear") { animate(Motion.travel) { _ = browser.store.send(.clearToday) } }
                    .buttonStyle(.borderless)
                    .help("Close today's tabs, except this one (⌘⇧K)")
            }
        }
    }
}

// MARK: - Rows

private struct NewTabRow: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        Button { browser.presentCommandBar(.newTab) } label: {
            Label("New Tab", systemImage: "plus")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }
}

private struct TabRow: View {
    enum Kind { case favorite, pinned, today }

    let tab: BrowserTab
    let kind: Kind
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @State private var hovering = false

    var body: some View {
        let status = browser.store.status(of: tab.id)
        HStack(spacing: 4) {
            Label {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    // Pinned tabs and favorites that are asleep read a little quieter.
                    .foregroundStyle(status.isAwake || kind == .today ? .primary : .secondary)
            } icon: {
                if status.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle)
                }
            }
            Spacer(minLength: 0)
            MediaBadge(tab: tab.id)
            if hovering {
                Button {
                    animate(Motion.travel) { _ = browser.store.send(.closeTab(tab.id)) }
                } label: {
                    Image(systemName: kind == .today ? "xmark" : "minus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                // A pinned tab's button only unloads it.
                .help(kind == .today ? "Close Tab (⌘W)" : "Unload Tab")
            }
        }
        .onHover { hovering = $0 }
        .help(tab.url.absoluteString)
        .contextMenu { TabMenu(tab: tab) }
        .tabDrag(tab, source: .row, session: drag)
    }
}

/// A playing tab's sound control, and its way back from Picture in Picture.
struct MediaBadge: View {
    let tab: TabID
    @Environment(Browser.self) private var browser

    var body: some View {
        let media = browser.media.state(of: tab)
        if browser.preferences.showMediaControls, media.playing || media.inPictureInPicture {
            HStack(spacing: 2) {
                if media.inPictureInPicture {
                    Button { browser.media.togglePictureInPicture(tab) } label: { Image(systemName: "pip.exit") }
                        .help("Back to the Page")
                }
                if media.playing {
                    Button { browser.media.toggleMute(tab) } label: {
                        Image(systemName: media.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(media.muted ? "Unmute" : "Mute")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
    }
}

/// A split as one row: its panes side by side, the focused one emphasized.
private struct SplitRow: View {
    let split: TabSplit
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag

    var body: some View {
        let state = browser.store.state
        let focused = state.selectedTabID
        HStack(spacing: 6) {
            Image(systemName: split.axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2")
                .foregroundStyle(.secondary)
            ForEach(split.tabs, id: \.self) { id in
                if let tab = state.tabs[id] {
                    HStack(spacing: 4) {
                        Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: 14)
                        Text(tab.displayTitle)
                            .lineLimit(1)
                            .fontWeight(focused == id ? .semibold : .regular)
                        MediaBadge(tab: id)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { browser.store.send(.selectTab(id)) }
                    .help(tab.displayTitle)
                    .tabDrag(tab, source: .row, session: drag)
                }
            }
        }
        .contextMenu { SplitMenu(tab: split.tabs[0]) }
    }
}

// MARK: - Spaces

/// Every Space, as buttons. Hold a dragged tab over one to open it and drop the tab inside.
private struct SpaceBar: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let state = browser.store.state
        HStack(spacing: 2) {
            ForEach(state.spaces) { space in
                let active = space.id == state.activeSpaceID
                Button { animate(Motion.swap) { _ = browser.store.send(.switchSpace(space.id)) } } label: {
                    SpaceIcon(icon: space.icon, name: space.name, size: 13)
                        .frame(width: 28, height: 24)
                        .foregroundStyle(active ? AnyShapeStyle(Theme.accent(space.hue, scheme)) : AnyShapeStyle(.secondary))
                        .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help(space.name)
                .contextMenu { SpaceMenu(space: space) }
                .springLoadingBehavior(.enabled)
                .dropDestination(for: String.self) { items, _ in browser.drop(items, on: .space(space.id)) }
            }
            Spacer(minLength: 4)
            Button {
                animate(Motion.swap) { _ = browser.store.send(.createSpace(name: "Space \(state.spaces.count + 1)")) }
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("New Space (⌘⇧N)")
        }
    }
}

// MARK: - Menus

/// What you can do with a split, from its row, its panes and the menu bar.
struct SplitMenu: View {
    let tab: TabID
    @Environment(Browser.self) private var browser

    var body: some View {
        let store = browser.store
        let split = store.state.activeSpace.split(containing: tab)
        Button(split?.axis == .horizontal ? "Stack Vertically" : "Arrange Side by Side") {
            animate(Motion.travel) { _ = store.send(.rotateSplit(tab)) }
        }
        Button("Make Panes Equal") {
            guard let split else { return }
            animate(Motion.travel) { _ = store.send(.resizeSplit(tab, fractions: Array(repeating: 1, count: split.tabs.count))) }
        }
        if (split?.tabs.count ?? 0) < TabSplit.maxPanes {
            Button("Add New Tab to Split") { browser.presentCommandBar(.split) }
        }
        Divider()
        Button("Separate Tabs") { animate(Motion.travel) { _ = store.send(.dissolveSplit(tab)) } }
    }
}

struct TabMenu: View {
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
        let media = browser.media.state(of: tab.id)
        if media.playing || media.hasVideo || media.inPictureInPicture {
            Divider()
            if media.playing { Button(media.muted ? "Unmute Tab" : "Mute Tab") { browser.media.toggleMute(tab.id) } }
            Button(media.playing ? "Pause" : "Play") { browser.media.togglePlayback(tab.id) }
            if media.hasVideo || media.inPictureInPicture {
                Button(media.inPictureInPicture ? "Exit Picture in Picture" : "Picture in Picture") {
                    browser.media.togglePictureInPicture(tab.id)
                }
            }
        }
        Divider()
        if let selected = state.selectedTab, selected.id != tab.id, state.activeSpace.split(containing: tab.id) == nil {
            let selected = selected.id
            Button("Open in Split View") {
                animate(Motion.travel) { _ = browser.store.send(.splitTab(tab.id, beside: selected, edge: .trailing)) }
            }
        }
        if state.activeSpace.split(containing: tab.id) != nil {
            Button("Remove from Split") { animate(Motion.travel) { _ = browser.store.send(.leaveSplit(tab.id)) } }
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

/// Rename, icon, profile, delete: the same menu on the header and the Space bar.
struct SpaceMenu: View {
    let space: Space
    @Environment(Browser.self) private var browser

    static let icons: [(symbol: String, name: String)] = [
        ("sun.max", "Sun"), ("moon", "Moon"), ("briefcase", "Work"), ("house", "Home"), ("book", "Reading"),
        ("star", "Star"), ("heart", "Heart"), ("leaf", "Leaf"), ("bolt", "Bolt"), ("flame", "Flame"),
        ("globe.americas", "Globe"), ("music.note", "Music"), ("graduationcap", "School"), ("cart", "Shopping"),
        ("paintpalette", "Art"), ("chevron.left.forwardslash.chevron.right", "Code"),
    ]

    var body: some View {
        let state = browser.store.state
        Button("Rename…") { browser.renameSpace = space.id }
        Picker("Icon", selection: Binding(get: { space.icon }, set: { browser.store.send(.setSpaceIcon(space.id, $0)) })) {
            Text("First Letter").tag(String?.none)
            Divider()
            ForEach(Self.icons, id: \.symbol) { icon in
                Label(icon.name, systemImage: icon.symbol).tag(Optional(icon.symbol))
            }
        }
        Menu("Profile") {
            ForEach(state.profiles) { profile in
                Toggle(profile.name, isOn: Binding(get: { space.profileID == profile.id },
                                                   set: { if $0 { browser.store.send(.assignProfile(space.id, profile.id)) } }))
            }
            Divider()
            Button("Manage Profiles…") { browser.openSettings("profiles") }
        }
        Button("Space Settings…") { browser.openSettings("spaces") }
        if state.spaces.count > 1 {
            Divider()
            Button("Delete Space", role: .destructive) { animate(Motion.swap) { _ = browser.store.send(.deleteSpace(space.id)) } }
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
                Label("\(activity.client) · \(activity.tool.replacingOccurrences(of: "_", with: " "))",
                      systemImage: activity.succeeded ? "sparkles" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
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

extension Preferences.Density {
    var rowSize: SidebarRowSize {
        switch self {
        case .compact: .small
        case .comfortable: .medium
        case .roomy: .large
        }
    }
}
