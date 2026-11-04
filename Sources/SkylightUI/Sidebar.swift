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
            // With the address bar hidden, extensions still get a row.
            if prefs.extensionPlacement == .toolbar || !prefs.shows(.addressBar) {
                ExtensionStrip(compact: false).frame(maxWidth: .infinity, alignment: .leading).transition(.opacity)
            }

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
                    if browser.preferences.extensionPlacement != .toolbar { ExtensionStrip(compact: true) }
                }
                .padding(.leading, 12)
                .padding(.trailing, browser.extensions.enabled.isEmpty || browser.preferences.extensionPlacement == .toolbar ? 12 : 6)
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
    @Environment(TabDrag.self) private var drag

    var body: some View {
        let state = browser.store.state
        let tabs = state.favoriteTabs
        let dropIndex: Int? = if case let .favorites(index)? = drag.target { index } else { nil }
        let dragged = drag.item?.id
        if !tabs.isEmpty || drag.isDragging {
            let columns = tabs.count + (dropIndex == nil ? 0 : 1) < 4 ? 3 : 4
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: columns), spacing: 7) {
                // The tile being dragged keeps its place (and its gesture) but steps back.
                let others = tabs.filter { $0.id != dragged }
                ForEach(tabs) { tab in
                    if let dropIndex, tab.id != dragged, others.firstIndex(where: { $0.id == tab.id }) == dropIndex {
                        DropSlot(radius: 12).frame(height: 46).id("slot")
                    }
                    FavoriteTile(tab: tab, selected: state.selectedTabID == tab.id, selection: selection)
                        .opacity(tab.id == dragged && dropIndex != nil ? 0.25 : 1)
                        .reportFrame { drag.favoriteTiles[tab.id] = $0 }
                        .transition(Arrive(scale: 0.85))
                }
                if let dropIndex, dropIndex >= others.count {
                    DropSlot(radius: 12).frame(height: 46).id("slot")
                }
                if tabs.isEmpty, dropIndex == nil {
                    Text("Drop here to favorite")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .gridCellColumns(columns)
                }
            }
            .motion(Motion.travel, value: state.favorites)
            .motion(Motion.travel, value: dropIndex)
            .reportFrame { drag.favoritesFrame = $0 }
            .onDisappear { drag.favoritesFrame = .zero }
        }
    }
}

/// Where a dragged tab will land.
struct DropSlot: View {
    var radius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(.tint.opacity(0.7))
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: radius, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    let selected: Bool
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser
    @Environment(TabDrag.self) private var drag
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
            .tabDrag(tab.id, source: .favorite, drag: drag, browser: browser)
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
    @Environment(TabDrag.self) private var drag

    var body: some View {
        let pitch = browser.preferences.density.rowHeight + 2
        let pinnedDrop: Bool = if case .section(.pinned, _)? = drag.target { true } else { false }
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                TabList(space: space, section: .pinned, selection: selection)
                    // Empty, it's a thin strip that still takes drops, and grows while you drag.
                    .frame(maxWidth: .infinity, minHeight: drag.isDragging && space.pinned.isEmpty ? pitch : 6, alignment: .top)
                    .overlay {
                        if drag.isDragging, space.pinned.isEmpty, !pinnedDrop {
                            Text("Drop here to pin").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                                .transition(.opacity)
                        }
                    }

                if !space.pinned.isEmpty || pinnedDrop {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .transition(.opacity)
                }

                if browser.preferences.shows(.newTab) { NewTabRow() }
                TabList(space: space, section: .today, selection: selection)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .motion(Motion.travel, value: space.pinned)
            .motion(Motion.travel, value: space.today)
            .motion(Motion.travel, value: space.splits)
            .motion(Motion.travel, value: drag.isDragging)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { drag.rowPitch = pitch }
        .onChange(of: pitch) { _, new in drag.rowPitch = new }
    }
}

/// One section's rows. While a tab is dragged over it, the rows part to show where it will land.
private struct TabList: View {
    let space: Space
    let section: SkylightCore.TabSection
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser
    @Environment(TabDrag.self) private var drag

    var body: some View {
        let state = browser.store.state
        let rows = SidebarRows.make(space[section], space: space)
        let dragged = drag.item?.id
        let slot = dropSlot(rows: rows, dragged: dragged)
        let others = rows.filter { dragged == nil || !$0.contains(dragged!) }
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 0).reportFrame { drag.listTops[section] = $0.minY }
            ForEach(rows, id: \.self) { row in
                let isDragged = dragged.map(row.contains) ?? false
                if let slot, !isDragged, others.firstIndex(of: row) == slot {
                    DropSlot().frame(height: browser.preferences.density.rowHeight)
                }
                Group {
                    if row.count > 1, let split = space.split(containing: row[0]) {
                        SplitRow(split: split, section: section, selection: selection)
                    } else if let tab = state.tabs[row[0]] {
                        TabRow(tab: tab, pinned: section == .pinned, selected: space.selectedTabID == tab.id, selection: selection)
                    }
                }
                // The dragged row keeps its place in the hierarchy (and its gesture), folded away.
                .frame(height: isDragged && drag.target != nil ? 0 : nil, alignment: .top)
                .opacity(isDragged && drag.target != nil ? 0 : isDragged ? 0.4 : 1)
                .clipped()
                .transition(Arrive(anchor: .top, scale: 0.98))
            }
            if let slot, slot >= others.count {
                DropSlot().frame(height: browser.preferences.density.rowHeight)
            }
        }
        .reportFrame { drag.sectionFrames[section] = $0 }
    }

    /// The target is counted in tabs; the sidebar draws rows (a split is one row).
    private func dropSlot(rows: [[TabID]], dragged: TabID?) -> Int? {
        guard case let .section(target, index)? = drag.target, target == section else { return nil }
        var count = 0, slot = 0
        for row in rows where dragged.map({ !row.contains($0) }) ?? true {
            if count >= index { break }
            count += row.count
            slot += 1
        }
        return slot
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
    @Environment(TabDrag.self) private var drag
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
            MediaBadge(tab: tab.id)
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
        .tabDrag(tab.id, source: .sidebar, drag: drag, browser: browser)
        .contextMenu { TabMenu(tab: tab) }
    }
}

/// A playing tab's sound control, and its way back from Picture in Picture.
struct MediaBadge: View {
    let tab: TabID
    @Environment(Browser.self) private var browser

    var body: some View {
        let media = browser.media.state(of: tab)
        if browser.preferences.showMediaControls, media.playing || media.inPictureInPicture {
            HStack(spacing: 0) {
                if media.inPictureInPicture {
                    badge("pip.exit", help: "Back to the page") { browser.media.togglePictureInPicture(tab) }
                }
                if media.playing {
                    badge(media.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: media.muted ? "Unmute" : "Mute") {
                        browser.media.toggleMute(tab)
                    }
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !media.muted)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
        }
    }

    private func badge(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)).frame(width: 20, height: 20).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// A split as one row: its panes side by side (or stacked, like the card), the focused one lit.
private struct SplitRow: View {
    let split: TabSplit
    let section: SkylightCore.TabSection
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser
    @Environment(TabDrag.self) private var drag
    @State private var hovering = false

    var body: some View {
        let state = browser.store.state
        let selected = state.activeSpace.selectedTabID
        let active = selected.map(split.tabs.contains) ?? false
        HStack(spacing: 3) {
            ForEach(split.tabs, id: \.self) { id in
                if let tab = state.tabs[id] {
                    SplitPaneChip(tab: tab, focused: active && selected == id, dimmed: section == .pinned && !browser.store.status(of: id).isAwake)
                        .frame(maxWidth: .infinity)
                        .tabDrag(id, source: .sidebar, drag: drag, browser: browser)
                }
            }
            if hovering {
                Menu {
                    SplitMenu(tab: split.tabs[0])
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 20)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .padding(3)
        .frame(height: browser.preferences.density.rowHeight)
        .background {
            if active {
                Color.clear.surface(.selected, lifted: true).matchedGeometryEffect(id: "selection", in: selection)
            } else if hovering {
                Color.clear.surface(.hover)
            }
        }
        .contentShape(.rect)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .contextMenu { SplitMenu(tab: split.tabs[0]) }
    }
}

private struct SplitPaneChip: View {
    let tab: BrowserTab
    let focused: Bool
    let dimmed: Bool
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: 14)
                .opacity(dimmed ? 0.7 : 1)
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: focused ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            MediaBadge(tab: tab.id)
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(focused ? 0.09 : hovering ? 0.05 : 0))
        }
        .contentShape(.rect)
        .onTapGesture { animate(Motion.travel) { _ = browser.store.send(.selectTab(tab.id)) } }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .help(tab.displayTitle)
    }
}

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
            Divider()
        }
        if let selected = state.selectedTab, selected.id != tab.id, !tab.url.isSkylightPage, !selected.url.isSkylightPage,
           state.activeSpace.split(containing: tab.id) == nil {
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
    @Environment(TabDrag.self) private var drag
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
                let dropping = drag.target == .space(space.id)
                Button { animate(Motion.swap) { _ = browser.store.send(.switchSpace(space.id)) } } label: {
                    SpaceIcon(icon: space.icon, name: space.name, size: 12)
                        .foregroundStyle(active || dropping ? AnyShapeStyle(Theme.accent(space.hue, scheme)) : AnyShapeStyle(.tertiary))
                        .frame(width: 26, height: 26)
                        .surface(active || dropping ? .selected : nil, radius: 8, lifted: active || dropping)
                        .scaleEffect(dropping ? 1.18 : 1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(space.name)
                .contextMenu { SpaceMenu(space: space) }
                .reportFrame { drag.spaceButtons[space.id] = $0 }
                .onDisappear { drag.spaceButtons[space.id] = nil }
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
