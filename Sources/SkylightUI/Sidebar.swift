import AppKit
import SkylightAgent
import SkylightBrowser
import SkylightCore
import SwiftUI

/// SwiftUI has its own `Tab`.
typealias BrowserTab = SkylightCore.Tab

/// A source list, like Finder's or Mail's: favorites shared by every Space, then the Space's pinned
/// tabs and today's tabs. Spaces switch from the bar at the bottom, or with a two-finger swipe.
struct Sidebar: View {
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @Environment(\.colorScheme) private var scheme
    @State private var drop = SidebarDropState()
    @State private var viewport: CGFloat = 0
    @State private var swipe = SpaceSwipe()

    private static let coordinates = "sidebar.list"

    /// No page in front of the theme's picture, which then fills the window.
    private var showingScene: Bool {
        let bar = browser.commandBar
        return browser.preferences.sceneOnNewTab && (browser.store.state.selectedTab == nil || bar.isPresented && bar.mode == .newTab)
    }

    var body: some View {
        let state = browser.store.state
        let space = state.activeSpace
        let prefs = browser.preferences
        let order = prefs.sidebarOrder
        let palette = prefs.skyBackdrop ? prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue) : nil
        let lines = SidebarLines(space: space, showsNewTab: prefs.shows(.newTab), todayFirst: order.todayFirst,
                                 showsHints: prefs.showsDropHints || drag.active != nil)

        VStack(spacing: 0) {
            if !order.favoritesLast { favorites }
            ScrollView {
                list(lines, space: space)
                    // Down to the bottom, so a tab dropped below the rows lands at the end.
                    .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
                    .contentShape(.rect)
                    .coordinateSpace(.named(Self.coordinates))
                    .onDrop(of: SidebarDropDelegate.types,
                            delegate: SidebarDropDelegate(lines: lines, state: drop, drag: drag, browser: browser,
                                                          rowHeight: prefs.density.rowHeight + 2))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
            .environment(\.sidebarDensity, prefs.density)
            .font(prefs.density.rowFont)
            if order.favoritesLast { favorites }
        }
        .offset(x: swipeShift)
        .background {
            // The window's backdrop (RootView) shows through. With a page over the rest of it, the
            // sidebar has the picture to itself and shows its subject, not its calm edge.
            if let image = palette?.image, let url = prefs.url(for: image), !showingScene {
                var art = image
                let _ = art.focusX = image.sidebarFocusX
                ThemeImageView(url: url, image: art).ignoresSafeArea().transition(.opacity)
            }
            // Strongest behind the tabs, clearing below them so the art can breathe, and back
            // again for the Space switcher.
            if let scrim = palette?.scrim {
                let veil = Color(scrim.color)
                LinearGradient(stops: [.init(color: veil.opacity(min(scrim.opacity * 1.5, 1)), location: 0),
                                       .init(color: veil.opacity(scrim.opacity), location: 0.55),
                                       .init(color: veil.opacity(scrim.opacity * 0.2), location: 0.8),
                                       .init(color: veil.opacity(scrim.opacity * 0.9), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            if space.tint != .none {
                // Weaker in dark mode, where the same amount turns warm colors muddy.
                let wash = Theme.wash(space.hue, scheme)
                let strength = space.tint == .strong ? (scheme == .dark ? 0.22 : 0.30) : (scheme == .dark ? 0.11 : 0.14)
                LinearGradient(colors: [wash.opacity(strength), wash.opacity(strength * 0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
        .animation(Motion.resolved(Motion.arrive), value: showingScene)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if let update = browser.readyUpdate { UpdateCard(update: update) }
                if prefs.shows(.agentActivity) { AgentActivityBadge() }
                ForEach(Preferences.SidebarItem.actions.filter(prefs.shows)) { SidebarActionRow(item: $0) }
                if !prefs.moreSidebarItems.isEmpty { SidebarMore(items: prefs.moreSidebarItems) }
                if prefs.spaceBarStyle != .hidden {
                    SpaceBar(style: prefs.spaceBarStyle)
                } else {
                    // The menu's button stays when the Spaces don't.
                    HStack {
                        SkylightMenuButton()
                        Spacer()
                    }
                }
            }
            .motion(Motion.arrive, value: browser.readyUpdate?.version)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .modifier(ThemeInk(palette: palette))
        // A different Space is a different list: crossfade rather than morph one into the other.
        .id(space.id)
        .transition(.opacity)
        // However the Space changed: the bar, the keyboard, a swipe, an agent.
        .motion(Motion.swap, value: space.id)
        // Outside the `id`, which would end a swipe the moment it changes the Space.
        .background { SpaceSwipeArea(handle: handleSwipe) }
    }

    /// With Reduce Motion the list stays put, and the Space only fades.
    private var swipeShift: CGFloat {
        guard !Motion.reduceMotion else { return 0 }
        let state = browser.store.state
        return swipe.shift(canMove: state.spaces.indices.contains(state.activeSpaceIndex + swipe.direction))
    }

    private func handleSwipe(_ event: SpaceSwipe.Event) -> SpaceSwipe.Response {
        var next = swipe
        let response = next.handle(event)
        guard case let .finished(step) = response else {
            // Every scroll in the window comes through here, and most change nothing.
            if next != swipe { swipe = next }
            return response
        }
        if let step { browser.store.send(.switchSpaceByOffset(step)) }
        animate(Motion.travel) { swipe = next }
        return response
    }

    /// A grid of tiles, as in Arc, shared by every Space, at the top or bottom of the sidebar.
    @ViewBuilder
    private var favorites: some View {
        let state = browser.store.state
        if browser.preferences.shows(.favorites), !state.favorites.isEmpty || drag.active != nil {
            FavoritesGrid(tabs: state.favoriteTabs, selected: state.selectedTabID)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
    }

    /// Every line, each moved aside as a drag needs. Frames are measured before the move, so the
    /// drag is hit-tested against where rows belong, not where they've slid to.
    private func list(_ lines: SidebarLines, space: Space) -> some View {
        let hidden = drop.hidden.flatMap { id in lines.lines.firstIndex { $0.id == id } }
        return VStack(spacing: 0) {
            ForEach(Array(lines.lines.enumerated()), id: \.element.id) { index, line in
                self.line(line, space: space)
                    .opacity(index == hidden ? 0 : 1)
                    .offset(y: drop.shift(of: index, hidden: hidden))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinates)) } action: { [drop] in
                        drop.frames[line.id] = $0
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            // Where the tab will land: a soft slot in the gap.
            if case let .gap(before, box, _)? = drop.hover {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(0.06))
                    .frame(height: max(drop.gapHeight - 2, 0))
                    .padding(.leading, box.isFolder ? SidebarMetrics.indent : 0)
                    .offset(y: lines.gapTop(before: before, frames: drop.frames, hidden: hidden, lift: drop.hiddenHeight) + 1)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            // The tab being dragged, lifted and following the pointer while you reorder. Over
            // another tab it steps aside, so the split that row shows can be seen.
            if let id = drag.active?.id, let pointer = drop.pointer, let tab = browser.store.state.tabs[id] {
                DraggedRow(tab: tab, showing: !drop.isSplitting)
                    .offset(y: pointer.y - DraggedRow.height / 2)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, drop.extraRoom + 6)
    }

    @ViewBuilder
    private func line(_ line: SidebarLines.Line, space: Space) -> some View {
        let targeted = drop.isTargeting(line.id)
        switch line.kind {
        case .spaceHeader:
            SpaceHeader(space: space)
        case let .folder(folder):
            FolderRow(folder: folder, targeted: targeted)
        case let .row(ids, box, _):
            // A tab held over the row's middle shows beside it, as the split the row would become.
            // The same row view parts in two, so its glass flows apart instead of swapping rows.
            let joining = targeted ? drag.active?.id : nil
            let indent = box.isFolder ? SidebarMetrics.indent : 0
            if ids.count > 1, let split = space.split(containing: ids[0]) {
                SplitRow(split: split, joining: joining, indent: indent)
            } else if let tab = browser.store.state.tabs[ids[0]] {
                TabRow(tab: tab, kind: box == .today ? .today : .pinned, joining: joining, indent: indent)
            }
        case let .hint(text, target):
            let inFolder = if case .folder = target { true } else { false }
            if browser.preferences.showsDropHints || drag.active != nil {
                DropHint(text: text, targeted: targeted, indent: inFolder ? SidebarMetrics.indent : 0)
            } else {
                // Still a line, so a drag has somewhere to land once the hint comes back.
                Color.clear.frame(height: 6)
            }
        case .pinnedHeader:
            Text("Pinned").sidebarHeader()
        case .todayHeader:
            TodayHeader(space: space).sidebarHeader()
        case .newTab:
            NewTabRow()
        }
    }
}

/// The colors a theme sets for what's on it. Anything it leaves on Automatic stays the system's.
private struct ThemeInk: ViewModifier {
    let palette: ThemePalette?

    func body(content: Content) -> some View {
        if let palette, let text = palette.text {
            let secondary = palette.secondaryText.map { Color($0) } ?? Color(text).opacity(0.7)
            content
                .foregroundStyle(Color(text), secondary, secondary.opacity(0.75))
                .environment(\.rowSelection, palette.selection.map { Color($0) })
        } else {
            content.environment(\.rowSelection, palette?.selection.map { Color($0) })
        }
    }
}

/// A row at the foot of the sidebar. Symbols differ in width, so each gets the same slot.
private struct SidebarFootLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16)
            Text(title)
        }
        .foregroundStyle(.secondary)
        .sidebarRow()
    }
}

/// Things you can do, as rows at the foot of the sidebar.
private struct SidebarActionRow: View {
    let item: Preferences.SidebarItem
    @Environment(Browser.self) private var browser

    var body: some View {
        Button {
            switch item {
            case .settings: browser.openSettings()
            default: browser.store.send(.reopenClosedTab)
            }
        } label: {
            SidebarFootLabel(title: item.name, symbol: item == .settings ? "gearshape" : "arrow.uturn.backward")
        }
        .buttonStyle(.plain)
    }
}

/// What you've put away, one click from the foot of the sidebar.
private struct SidebarMore: View {
    let items: [Preferences.SidebarItem]
    @State private var open = false
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(spacing: 0) {
            if open {
                ForEach(items) { item in
                    switch item {
                    case .favorites: MoreFavorites()
                    case .newTab:
                        Button { browser.presentCommandBar(.newTab) } label: {
                            SidebarFootLabel(title: item.name, symbol: "plus")
                        }
                        .buttonStyle(.plain)
                    default: SidebarActionRow(item: item)
                    }
                }
            }
            Button {
                animate(Motion.travel) { open.toggle() }
            } label: {
                SidebarFootLabel(title: open ? "Less" : "More", symbol: open ? "chevron.down" : "ellipsis")
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MoreFavorites: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        FavoritesGrid(tabs: state.favoriteTabs, selected: state.selectedTabID)
            .padding(.vertical, 4)
    }
}

/// A dragged tab over the sidebar: its row, lifted off the list as a pane of glass.
private struct DraggedRow: View {
    static let height: CGFloat = 30

    let tab: BrowserTab
    let showing: Bool

    var body: some View {
        Label {
            Text(tab.shortTitle).lineLimit(1)
        } icon: {
            Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 7, style: .continuous))
        .scaleEffect(showing ? 1 : 0.96)
        .opacity(showing ? 1 : 0)
        // Steps aside gently, comes back at once.
        .motion(showing ? Motion.feedback : .easeInOut(duration: 0.3), value: showing)
    }
}

/// Favorites as tiles: the site's icon on a rounded square, the open one highlighted. Drop a tab
/// on a tile to put it before that one, or in the gap after the last.
private struct FavoritesGrid: View {
    let tabs: [BrowserTab]
    let selected: TabID?
    @Environment(Browser.self) private var browser

    private var columns: [GridItem] {
        let prefs = browser.preferences
        if prefs.favoritesPerRow > 0 {
            return Array(repeating: GridItem(.flexible(), spacing: 6), count: prefs.favoritesPerRow)
        }
        let widths = prefs.favoriteSize.widths
        return [GridItem(.adaptive(minimum: widths.lowerBound, maximum: widths.upperBound), spacing: 6)]
    }

    var body: some View {
        if tabs.isEmpty {
            Text("Drop a tab here to keep it in every Space")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .dropDestination(for: String.self) { items, _ in browser.drop(items, on: .favorites(index: 0)) }
        } else {
            LazyVGrid(columns: columns, spacing: 6) {
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
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let status = browser.store.status(of: tab.id)
        let size = browser.preferences.favoriteSize
        ZStack {
            if status.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: size.iconSize)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size.tileHeight)
        .modifier(surface(style: browser.preferences.favoriteStyle, cornerRadius: size.cornerRadius))
        .overlay(alignment: .topTrailing) {
            MediaBadge(tab: tab.id).controlSize(.mini).padding(1)
        }
        .contentShape(.rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { browser.store.send(.selectTab(tab.id)) }
        .contextMenu { TabMenu(tab: tab) }
        .tabDrag(tab, source: .row, session: drag)
        .help(tab.displayTitle)
        .accessibilityElement()
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func surface(style: Preferences.FavoriteStyle, cornerRadius: CGFloat) -> TileSurface {
        TileSurface(style: style, selected: selected, hovering: hovering,
                    color: Theme.accent(browser.store.state.activeSpace.hue, scheme), cornerRadius: cornerRadius)
    }
}

/// What a favorite sits on: a pane of glass, the same in the Space's color, or nothing until you
/// point at it or open it.
private struct TileSurface: ViewModifier {
    let style: Preferences.FavoriteStyle
    let selected: Bool
    let hovering: Bool
    let color: Color
    let cornerRadius: CGFloat
    @Environment(\.rowSelection) private var selection

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch style {
        case .glass:
            content.glassEffect(selected ? .regular.tint((selection ?? .accentColor).opacity(0.35)).interactive() : .regular.interactive(), in: shape)
        case .tinted:
            content.glassEffect(.regular.tint(color.opacity(selected ? 0.55 : 0.25)).interactive(), in: shape)
        case .plain:
            content.background(.quaternary.opacity(selected ? 1 : hovering ? 0.5 : 0), in: shape)
        }
    }
}

/// A folder of pinned tabs: click it to open or close it, drop tabs on it or between its tabs.
/// Its tabs are lines of their own, below it.
private struct FolderRow: View {
    let folder: TabFolder
    let targeted: Bool
    @Environment(Browser.self) private var browser
    @State private var editing = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        Label {
            if editing {
                TextField("Folder name", text: $name)
                    .inlineName()
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                HStack {
                    Text(folder.name).fadingTail()
                    Spacer(minLength: 4)
                    if !folder.isOpen, !folder.tabs.isEmpty {
                        Text("\(folder.tabs.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
        } icon: {
            Image(systemName: folder.isOpen ? "folder" : "folder.fill")
                .foregroundStyle(.secondary)
        }
        .sidebarRow(targeted: targeted)
        .onTapGesture { if !editing { setOpen(!folder.isOpen) } }
        .contextMenu { FolderMenu(folder: folder, rename: startEditing) }
        .onAppear { if browser.renameFolder == folder.id { startEditing() } }
        .onChange(of: browser.renameFolder) { _, id in if id == folder.id { startEditing() } }
    }

    private func setOpen(_ open: Bool) {
        animate(Motion.travel) { _ = browser.store.send(.setFolderOpen(folder.id, open)) }
    }

    private func startEditing() {
        browser.renameFolder = nil
        name = folder.name
        editing = true
        focusAndSelect { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        browser.store.send(.renameFolder(folder.id, name))
    }
}

private struct FolderMenu: View {
    let folder: TabFolder
    let rename: () -> Void
    @Environment(Browser.self) private var browser

    var body: some View {
        let store = browser.store
        let folders = store.state.activeSpace.folders
        let index = folders.firstIndex { $0.id == folder.id } ?? 0
        Button("Rename…", action: rename)
        Button(folder.isOpen ? "Close Folder" : "Open Folder") {
            animate(Motion.travel) { _ = store.send(.setFolderOpen(folder.id, !folder.isOpen)) }
        }
        if folders.count > 1 {
            Divider()
            if index > 0 {
                Button("Move Up") { animate(Motion.travel) { _ = store.send(.moveFolder(folder.id, to: index - 1)) } }
            }
            if index < folders.count - 1 {
                Button("Move Down") { animate(Motion.travel) { _ = store.send(.moveFolder(folder.id, to: index + 1)) } }
            }
        }
        Divider()
        Button("Delete Folder, Keep Tabs") { animate(Motion.travel) { _ = store.send(.deleteFolder(folder.id)) } }
        Button("Delete Folder and Its Tabs", role: .destructive) {
            animate(Motion.travel) { _ = store.send(.deleteFolder(folder.id, closeTabs: true)) }
        }
    }
}

/// An empty section's row: says what it's for, and lights up under a tab that would land there.
private struct DropHint: View {
    let text: String
    let targeted: Bool
    let indent: CGFloat

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .sidebarRow(targeted: targeted, indent: indent)
    }
}

// MARK: - Headers

/// The Space's name (click it to rename) and profile, with its menu. Hidden, it stays as a sliver:
/// renaming still happens here, and the Space's popover hangs off it.
private struct SpaceHeader: View {
    let space: Space
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @State private var editing = false
    @State private var hovering = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let style = browser.preferences.spaceHeaderStyle
        VStack(spacing: 0) {
            if style == .hidden, !editing {
                Color.clear.frame(height: 4)
            } else {
                row(large: style == .large).sidebarHeader(top: 4, large: style == .large)
            }
        }
        .frame(maxWidth: .infinity)
        .popover(isPresented: Binding(get: { browser.customizingSpace == space.id },
                                      set: { if !$0 { browser.customizingSpace = nil } }), arrowEdge: .trailing) {
            SpaceCustomizer(space: space)
        }
        .onChange(of: browser.renameSpace) { _, id in
            // Renaming the Space on screen happens right here, not in an alert.
            if id == space.id {
                browser.renameSpace = nil
                startEditing()
            }
        }
    }

    private func row(large: Bool) -> some View {
        let profile = browser.store.state.profile(space.profileID)
        return HStack(spacing: 6) {
            SpaceIcon(icon: space.icon, name: space.name, size: large ? 15 : 11)
                .foregroundStyle(Theme.accent(space.hue, scheme))
                .frame(width: large ? 20 : 14)
            if editing {
                TextField("Space name", text: $name)
                    .inlineName()
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(space.name)
                    .lineLimit(1)
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
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Space options")
            .opacity(browser.preferences.spaceMenuOnHover && !hovering ? 0 : 1)
        }
        .contentShape(.rect)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .contextMenu { SpaceMenu(space: space) }
    }

    private func startEditing() {
        name = space.name
        editing = true
        focusAndSelect { focused = true }
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
        HStack(spacing: 2) {
            Text("Today").fixedSize()
            Spacer(minLength: 4)
            if Tidy.candidates(space).count > 1 { TidyButton() }
            if !space.today.isEmpty {
                HeaderButton("Clear", systemImage: "arrow.down") {
                    animate(Motion.travel) { _ = browser.store.send(.clearToday) }
                }
                .help("Close today's tabs, except this one (⌘⇧K)")
            }
        }
    }
}

/// Gathers today's tabs into folders, the way you last asked (right-click to ask another way).
private struct TidyButton: View {
    @Environment(Browser.self) private var browser
    @State private var working = false
    @State private var asking = false
    @State private var how = ""

    var body: some View {
        HeaderButton("Tidy", systemImage: "sparkles", busy: working) { tidy(browser.preferences.tidyInstruction) }
            .disabled(working)
            .help(browser.tidyUsesModel
                  ? "Put today's tabs in folders \(label(browser.preferences.tidyInstruction)). Right-click to choose how."
                  : "Put today's tabs in folders by site. Turn on Apple Intelligence to group them any way you like.")
            .contextMenu {
                ForEach(["by topic", "by site", "by project", "work and personal"], id: \.self) { way in
                    Toggle(label(way).capitalized, isOn: Binding(get: { label(browser.preferences.tidyInstruction) == way },
                                                                set: { _ in tidy(way) }))
                }
                Divider()
                Button("Other…") {
                    how = browser.preferences.tidyInstruction
                    asking = true
                }
            }
            .popover(isPresented: $asking, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Group today's tabs…").font(.headline)
                    TextField("by client, by trip, to read later…", text: $how)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit {
                            asking = false
                            tidy(how)
                        }
                }
                .padding(12)
            }
    }

    private func label(_ way: String) -> String { way.isEmpty ? "by topic" : way }

    private func tidy(_ way: String) {
        browser.preferences.tidyInstruction = way == "by topic" ? "" : way
        working = true
        Task {
            let plan = await browser.tidyPlan(how: way)
            working = false
            animate(Motion.travel) { browser.applyTidy(plan.groups, in: plan.space) }
        }
    }
}

/// A small text button in a section header: an icon and a word, highlighted on hover.
private struct HeaderButton: View {
    let title: String
    let systemImage: String
    var busy = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String, busy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // In a narrow sidebar, just the icon.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) {
                    icon
                    Text(title)
                }
                .fixedSize()
                icon
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(hovering && isEnabled ? 0.08 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .animation(Motion.feedback, value: hovering)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var icon: some View {
        if busy {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: systemImage).imageScale(.small)
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
                .sidebarRow()
        }
        .buttonStyle(.plain)
    }
}

private struct TabRow: View {
    enum Kind { case favorite, pinned, today }

    let tab: BrowserTab
    let kind: Kind
    /// A dragged tab held over this one, which would split beside it.
    var joining: TabID?
    var indent: CGFloat = 0
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @Environment(\.sidebarDensity) private var density
    @State private var hovering = false
    @State private var editing = false
    @State private var name = ""
    @FocusState private var focused: Bool
    @Namespace private var glass

    var body: some View {
        let arriving = joining.flatMap { browser.store.state.tabs[$0] }
        let parted = arriving != nil
        // Held over, the row parts into two panes of glass: this tab's, and the arriving one's.
        GlassEffectContainer(spacing: SplitPane.blend) {
            HStack(spacing: SplitPane.gap) {
                content
                    .padding(.horizontal, parted ? SplitPane.inset : 0)
                    .frame(height: density.rowHeight - SplitPane.margin)
                    .glassEffect(parted ? .regular : .identity, in: SplitPane.shape)
                    .glassEffectID(tab.id, in: glass)
                if let arriving {
                    SplitPaneLabel(tab: arriving)
                        .splitPane(arriving.id, in: glass, height: density.rowHeight - SplitPane.margin, arriving: true)
                        .transition(Emerge())
                }
            }
        }
        // The pane's edge moves out, its name stays put.
        .padding(.leading, parted ? -SplitPane.inset : 0)
        .motion(Motion.flow, value: joining)
        .sidebarRow(selected: browser.store.state.selectedTabID == tab.id, highlights: !parted, indent: indent)
        .onHover { hovering = $0 }
        .onTapGesture {
            if browser.store.state.selectedTabID != tab.id { browser.store.send(.selectTab(tab.id)) }
        }
        // Double-click the name to rename it. Alongside the click, so selecting doesn't wait.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !editing, canRename { startEditing() } })
        .help("\(tab.displayTitle)\n\(tab.url.absoluteString)")
        .contextMenu { TabMenu(tab: tab) }
        .tabDrag(tab, source: .row, session: drag)
        .onAppear { if browser.renameTab == tab.id { startEditing() } }
        .onChange(of: browser.renameTab) { _, id in if id == tab.id { startEditing() } }
    }

    private var content: some View {
        let status = browser.store.status(of: tab.id)
        return HStack(spacing: 4) {
            Label {
                if editing {
                    TextField("Tab name", text: $name)
                        .inlineName()
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, now in if !now { commit() } }
                } else {
                    Text(tab.shortTitle)
                        .fadingTail()
                        // Pinned tabs and favorites that are asleep read a little quieter.
                        .foregroundStyle(status.isAwake || kind == .today ? .primary : .secondary)
                }
            } icon: {
                if status.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle)
                        .opacity(status.isAwake || kind == .today ? 1 : 0.6)
                }
            }
            Spacer(minLength: 0)
            MediaBadge(tab: tab.id)
            // Not while renaming, and not on a pinned tab that's already asleep: there'd be nothing to do.
            if hovering, !editing, joining == nil, kind == .today || status.isAwake {
                Button {
                    animate(Motion.travel) { _ = browser.store.send(.closeTab(tab.id)) }
                } label: {
                    Image(systemName: kind == .today ? "xmark" : "minus")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(RowActionStyle())
                // A pinned tab's button only unloads it.
                .help(kind == .today ? "Close Tab (⌘W)" : "Unload Tab")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.resolved(Motion.feedback), value: hovering)
        // Unloading a pinned tab: its row quiets down, and the button goes.
        .animation(Motion.resolved(Motion.travel), value: status.isAwake)
    }

    /// Favorites and split panes have no name in their row to edit.
    private var canRename: Bool {
        let state = browser.store.state
        return !state.isFavorite(tab.id) && state.activeSpace.split(containing: tab.id) == nil
    }

    private func startEditing() {
        browser.renameTab = nil
        name = tab.shortTitle
        editing = true
        focusAndSelect { focused = true }
    }

    /// An empty name goes back to the page's own title.
    private func commit() {
        guard editing else { return }
        editing = false
        if name != tab.shortTitle { browser.store.send(.renameTab(tab.id, name)) }
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

/// A split as one row: each pane its own pill of glass, a gap between them, the focused one's name
/// in bold. The page already outlines the focused pane, so the row doesn't light it up as well.
private struct SplitRow: View {
    let split: TabSplit
    /// A dragged tab held over the row, which would join the split.
    var joining: TabID?
    var indent: CGFloat = 0
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @Environment(\.sidebarDensity) private var density
    @Namespace private var glass

    var body: some View {
        let state = browser.store.state
        let focused = state.selectedTabID
        let selected = split.tabs.contains { $0 == focused }
        let panes = split.tabs + (joining.map { [$0] } ?? [])
        GlassEffectContainer(spacing: SplitPane.blend) {
            HStack(spacing: SplitPane.gap) {
                ForEach(panes, id: \.self) { id in
                    if let tab = state.tabs[id] {
                        let arriving = id == joining
                        let lit = selected && focused == id
                        SplitPaneLabel(tab: tab, emphasized: lit)
                            .splitPane(id, in: glass, height: density.rowHeight - SplitPane.margin,
                                       arriving: arriving)
                            .contentShape(.rect)
                            .onTapGesture { browser.store.send(.selectTab(id)) }
                            .help(tab.displayTitle)
                            .tabDrag(tab, source: .row, session: drag)
                            .transition(Emerge())
                    }
                }
            }
        }
        .padding(.leading, -SplitPane.inset)
        .motion(Motion.flow, value: joining)
        .motion(Motion.travel, value: focused)
        .sidebarRow(highlights: false, indent: indent)
        .contextMenu { SplitMenu(tab: split.tabs[0]) }
    }
}

/// A pane's icon and name in a split row.
private struct SplitPaneLabel: View {
    let tab: BrowserTab
    var emphasized = false

    var body: some View {
        HStack(spacing: 4) {
            Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: 14)
            Text(tab.shortTitle)
                .fadingTail()
                .fontWeight(emphasized ? .semibold : .regular)
            Spacer(minLength: 0)
            MediaBadge(tab: tab.id)
        }
    }
}

/// How a split's panes sit in their row.
enum SplitPane {
    /// Room between panes: enough that they read as two, close enough to read as one row.
    static let gap: CGFloat = 4
    /// Glass this close flows together, so a pane parting from another is pulled out of it.
    /// Under the gap, so panes at rest stay apart.
    static let blend: CGFloat = 3
    /// Space between a pane's edge and its icon.
    static let inset: CGFloat = 6
    /// How much shorter a pane is than its row.
    static let margin: CGFloat = 6
    static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    /// A tab held over a row is the one thing tinted, and outlined, so the split it would make is
    /// plain to see.
    static func glass(arriving: Bool) -> Glass {
        arriving ? .regular.tint(.accentColor.opacity(0.45)) : .regular.interactive()
    }
}

extension View {
    /// One pane of a split in a sidebar row, as a pill of glass that morphs with its neighbours.
    fileprivate func splitPane(_ id: TabID, in space: Namespace.ID, height: CGFloat, arriving: Bool = false) -> some View {
        modifier(SplitPaneChrome(id: id, space: space, height: height, arriving: arriving))
    }
}

/// A pane's glass, its own hover, and the outline on one that's arriving.
private struct SplitPaneChrome: ViewModifier {
    let id: TabID
    let space: Namespace.ID
    let height: CGFloat
    let arriving: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SplitPane.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background { SplitPane.shape.fill(.primary.opacity(hovering && !arriving ? 0.06 : 0)) }
            .overlay { SplitPane.shape.strokeBorder(.tint, lineWidth: 1.5).opacity(arriving ? 1 : 0) }
            .glassEffect(SplitPane.glass(arriving: arriving), in: SplitPane.shape)
            .glassEffectID(id, in: space)
            .glassEffectTransition(.matchedGeometry)
            .animation(Motion.resolved(Motion.feedback), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Spaces

/// Every Space, as buttons. Hold a dragged tab over one to open it and drop the tab inside.
private struct SpaceBar: View {
    let style: Preferences.SpaceBarStyle
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let state = browser.store.state
        HStack(spacing: 2) {
            SkylightMenuButton()
                .padding(.trailing, 4)
            ForEach(state.spaces) { space in
                let active = space.id == state.activeSpaceID
                Button { animate(Motion.swap) { _ = browser.store.send(.switchSpace(space.id)) } } label: {
                    if style == .dots {
                        Circle()
                            .fill(active ? AnyShapeStyle(Theme.accent(space.hue, scheme)) : AnyShapeStyle(.tertiary))
                            .frame(width: 7, height: 7)
                            .frame(width: 18, height: 24)
                            .contentShape(.rect)
                    } else {
                        SpaceIcon(icon: space.icon, name: space.name, size: 13)
                            .frame(width: 28, height: 24)
                            .foregroundStyle(active ? AnyShapeStyle(Theme.accent(space.hue, scheme)) : AnyShapeStyle(.secondary))
                            .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                    }
                }
                .buttonStyle(.borderless)
                .help(space.name)
                .contextMenu { SpaceMenu(space: space) }
                .springLoadingBehavior(.enabled)
                .dropDestination(for: String.self) { items, _ in browser.drop(items, on: .space(space.id)) }
            }
            Spacer(minLength: 4)
            Button {
                browser.newSpace()
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
        if !favorite, state.activeSpace.split(containing: tab.id) == nil {
            Button("Rename…") { browser.renameTab = tab.id }
        }
        if tab.customTitle != nil {
            Button("Use Page Title") { browser.store.send(.renameTab(tab.id, "")) }
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
        Menu("Move to Folder") {
            let space = state.space(containing: tab.id) ?? state.activeSpace
            let current = space.folder(containing: tab.id)
            ForEach(space.folders) { folder in
                Button(folder.name) { animate(Motion.travel) { _ = browser.store.send(.moveTabToFolder(tab.id, folder: folder.id)) } }
                    .disabled(folder.id == current?.id)
            }
            if !space.folders.isEmpty { Divider() }
            Button("New Folder") { animate(Motion.travel) { browser.newFolder(with: [tab.id]) } }
            if current != nil {
                Button("Remove from Folder") { animate(Motion.travel) { _ = browser.store.send(.moveTabToFolder(tab.id, folder: nil)) } }
            }
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

/// Rename, look, profile, delete: the same menu on the header and the Space bar.
struct SpaceMenu: View {
    let space: Space
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme

    /// The ones short enough for a menu. The popover has them all.
    static let icons = Array(IconSearch.symbols.prefix(16))

    static let colors: [(hue: Double, name: String)] = [
        (0.99, "Red"), (0.07, "Orange"), (0.13, "Yellow"), (0.35, "Green"), (0.47, "Teal"),
        (0.58, "Blue"), (0.67, "Indigo"), (0.77, "Purple"), (0.90, "Pink"),
    ]

    /// Whether a Space's hue is close enough to a preset to call it that color.
    static func matches(_ hue: Double, _ preset: Double) -> Bool { abs(hue - preset) < 0.005 }

    var body: some View {
        let state = browser.store.state
        @Bindable var prefs = browser.preferences
        Button("Rename…") { browser.renameSpace = space.id }
        if space.id == state.activeSpaceID {
            Button("New Folder") { animate(Motion.travel) { browser.newFolder() } }
        }
        Menu("Icon") {
            Toggle("First Letter", isOn: Binding(get: { space.icon == nil },
                                                 set: { if $0 { browser.store.send(.setSpaceIcon(space.id, nil)) } }))
            Divider()
            ForEach(Self.icons, id: \.symbol) { icon in
                Toggle(isOn: Binding(get: { space.icon == icon.symbol },
                                     set: { if $0 { browser.store.send(.setSpaceIcon(space.id, icon.symbol)) } })) {
                    Label(icon.name, systemImage: icon.symbol)
                }
            }
            Divider()
            Button("More Icons and Emoji…") { browser.customizeSpace(space.id) }
        }
        Menu("Color") {
            ForEach(Self.colors, id: \.name) { color in
                Toggle(isOn: Binding(get: { Self.matches(space.hue, color.hue) },
                                     set: { if $0 { browser.store.send(.setSpaceHue(space.id, color.hue)) } })) {
                    Label { Text(color.name) } icon: { Image(nsImage: Theme.swatch(color.hue, scheme)) }
                }
            }
            Divider()
            Button("Custom…") { browser.customizeSpace(space.id) }
        }
        Menu("Sidebar Tint") {
            ForEach(SpaceTint.allCases) { tint in
                Toggle(tint.name, isOn: Binding(get: { space.tint == tint },
                                                set: { if $0 { browser.store.send(.setSpaceTint(space.id, tint)) } }))
            }
        }
        Menu("Sky") {
            Toggle("Same as the App", isOn: Binding(get: { space.themeID == nil },
                                                    set: { if $0 { browser.store.send(.setSpaceTheme(space.id, nil)) } }))
            Divider()
            ForEach(prefs.themes) { theme in
                Toggle(theme.name, isOn: Binding(get: { space.themeID == theme.id },
                                                 set: { if $0 { browser.store.send(.setSpaceTheme(space.id, theme.id)) } }))
            }
            Divider()
            Toggle("Show Theme Behind the Sidebar", isOn: $prefs.skyBackdrop)
        }
        Menu("Profile") {
            ForEach(state.profiles) { profile in
                Toggle(profile.name, isOn: Binding(get: { space.profileID == profile.id },
                                                   set: { if $0 { browser.store.send(.assignProfile(space.id, profile.id)) } }))
            }
            Divider()
            Button("New Profile for This Space…") { browser.newProfile(for: space.id) }
            Button("Manage Profiles…") { browser.openSettings("profiles") }
        }
        Button("Duplicate Space") { animate(Motion.swap) { _ = browser.store.send(.duplicateSpace(space.id)) } }
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

/// A downloaded update, at the bottom of the sidebar: one tile, like the pinned ones, that
/// relaunches Skylight to install it. Otherwise it installs when Skylight next quits; the context
/// menu puts the tile away until then.
private struct UpdateCard: View {
    let update: ReadyUpdate
    @Environment(\.sidebarDensity) private var density
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            Button { update.install() } label: {
                HStack {
                    Text("Relaunch to update")
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(density.rowFont.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10, style: .continuous))
            .help("Relaunch to update · v\(update.version)")
            .contextMenu {
                Button("Install When Skylight Quits") { animate(Motion.exit) { dismissed = true } }
            }
            .transition(Arrive(anchor: .bottom, scale: 0.94, rise: 8))
        }
    }
}

enum SidebarMetrics {
    /// How far a folder's tabs sit in from the folder.
    static let indent: CGFloat = 14
}

/// The window's backdrop behind the sidebar and toolbar: the desktop shows through, softly.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Focuses a name field, then selects its text so typing replaces it.
@MainActor
func focusAndSelect(_ focus: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        focus()
        // Only once the field has the cursor: before that, Select All would reach the page.
        DispatchQueue.main.async {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor { editor.selectAll(nil) }
        }
    }
}

extension View {
    /// A name edited in place, as in Finder: the text stays where it was, on a soft highlight
    /// rather than in a bordered box.
    func inlineName() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.background.opacity(0.75), in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.tint.opacity(0.45), lineWidth: 1))
            .padding(.horizontal, -4)
    }

    /// A long title runs on and fades out at the end of the row instead of ending in "…".
    func fadingTail(_ fade: CGFloat = 20) -> some View {
        lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                }
            }
    }
}

/// A small button in a row, with a box you can see: it shows on hover and dips when pressed.
struct RowActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }

    private struct Look: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: 20, height: 20)
                .foregroundStyle(hovering ? .primary : .secondary)
                .background(.primary.opacity(configuration.isPressed ? 0.18 : hovering ? 0.1 : 0), in: .rect(cornerRadius: 5, style: .continuous))
                .contentShape(.rect)
                .scaleEffect(configuration.isPressed ? 0.82 : 1)
                .animation(Motion.resolved(Motion.feedback), value: configuration.isPressed)
                .animation(Motion.resolved(Motion.feedback), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

