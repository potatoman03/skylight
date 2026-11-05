import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// One line of Skylight's menu. A row runs a menu bar command, so it does what the menu bar does
/// and shows the shortcut set there, yours included; or its own action; or opens a submenu.
struct MenuRow: Identifiable {
    enum Icon {
        case symbol(String)
        case site(BrowserTab)
    }

    let title: String
    let icon: Icon
    /// The menu bar command it runs, named as in `MainMenu`.
    var command: String?
    var enabled = true
    var action: (@MainActor () -> Void)?
    var submenu: [[MenuRow]] = []

    /// Two sites can share a title; a menu's commands never do.
    var id: String {
        if case let .site(tab) = icon { "\(tab.id)" } else { title }
    }
    var opensSubmenu: Bool { !submenu.isEmpty }

    /// The menu bar's item for this row.
    @MainActor var item: NSMenuItem? {
        command.flatMap { command in ShortcutMap.items(in: NSApp.mainMenu).first { $0.identifier?.rawValue == command } }
    }

    @MainActor var keys: String? {
        guard let item, !item.keyEquivalent.isEmpty else { return nil }
        return Shortcuts.keys(item.keyEquivalent, item.keyEquivalentModifierMask).joined()
    }
}

extension MenuRow {
    init(_ title: String, _ symbol: String, _ command: String, enabled: Bool = true) {
        self.init(title: title, icon: .symbol(symbol), command: command, enabled: enabled)
    }

    init(_ title: String, _ symbol: String, action: @escaping @MainActor () -> Void) {
        self.init(title: title, icon: .symbol(symbol), action: action)
    }

    init(_ title: String, _ symbol: String, submenu: [[MenuRow]]) {
        self.init(title: title, icon: .symbol(symbol), submenu: submenu)
    }
}

/// What's in the menu. Only what Skylight really does.
@MainActor
enum MenuContent {
    /// Favorites past this many stay in the sidebar, so the submenu fits a small window.
    private static let favoriteLimit = 8

    static func sections(_ browser: Browser) -> [[MenuRow]] {
        let state = browser.store.state
        let status = browser.selectedStatus
        let hasTab = state.selectedTabID != nil
        return [
            [
                MenuRow("New Tab", "plus", "newTab:"),
                MenuRow("New Space", "square.stack", "newSpace:"),
            ],
            [
                MenuRow("Favorites", "star", submenu: favorites(browser)),
                MenuRow("Downloads", "arrow.down.circle") { browser.showDownloads() },
                MenuRow("Extensions", "puzzlepiece.extension") { browser.openSettings("extensions") },
                MenuRow("History", "clock.arrow.circlepath", submenu: [[
                    MenuRow("Back", "chevron.backward", "goBack:", enabled: status.canGoBack),
                    MenuRow("Forward", "chevron.forward", "goForward:", enabled: status.canGoForward),
                    MenuRow("Reopen Closed Tab", "arrow.uturn.backward", "reopenTab:", enabled: !state.closedTabs.isEmpty),
                ]]),
                MenuRow("Developer", "chevron.left.forwardslash.chevron.right", submenu: [
                    [
                        MenuRow("Developer Tools", "hammer", "developerTools:", enabled: hasTab),
                        MenuRow("Boost This Site", "paintbrush", "boostSite:", enabled: hasTab),
                    ],
                    [
                        MenuRow("Show Packages Folder", "folder", "showPackages:"),
                        MenuRow("Copy Claude Code Command", "doc.on.doc", "copyAgentCommand:"),
                    ],
                ]),
            ],
            [
                MenuRow("Profiles", "person.crop.circle") { browser.openSettings("profiles") },
                MenuRow("Settings", "gearshape", "showSettings:"),
                MenuRow("Keyboard Shortcuts", "command", "showShortcuts:"),
            ],
        ]
    }

    private static func favorites(_ browser: Browser) -> [[MenuRow]] {
        let state = browser.store.state
        let selected = state.selectedTabID
        let favorite = selected.map(state.isFavorite) ?? false
        let pinned = selected.flatMap { state.space(containing: $0)?.section(of: $0) } == .pinned
        var commands = [MenuRow(favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star",
                                "toggleFavorite:", enabled: selected != nil)]
        if !favorite {
            commands.append(MenuRow(pinned ? "Unpin Tab" : "Pin Tab", pinned ? "pin.slash" : "pin", "togglePin:", enabled: selected != nil))
        }
        let sites = state.favoriteTabs.prefix(favoriteLimit).map { tab in
            MenuRow(title: tab.shortTitle, icon: .site(tab), action: { browser.store.send(.selectTab(tab.id)) })
        }
        return sites.isEmpty ? [commands] : [commands, sites]
    }
}

/// Where the pointer and keyboard are in an open menu. The page keeps keyboard focus: the arrow
/// keys are read before they reach it, so closing the menu has no focus to hand back.
@MainActor
@Observable
final class MenuSession {
    /// The highlighted row in the menu, across its sections.
    var row: Int?
    /// The row whose submenu is showing.
    var open: Int?
    /// The highlighted row in that submenu.
    var subrow: Int?
    /// Where the panels are, in the window's coordinates, for clicks.
    @ObservationIgnored var panels: [CGRect] = [.zero, .zero]

    @ObservationIgnored private let browser: Browser
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var hoverChange: Task<Void, Never>?

    /// Long enough to cross a row on the way to a submenu without it changing.
    private static let hoverDelay = Duration.milliseconds(130)

    init(browser: Browser) {
        self.browser = browser
    }

    var rows: [MenuRow] { MenuContent.sections(browser).flatMap(\.self) }

    var subrows: [MenuRow] {
        guard let open, rows.indices.contains(open) else { return [] }
        return rows[open].submenu.flatMap(\.self)
    }

    func start() {
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.press(event) ?? false } ? nil : event
            },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.click(event) ?? false } ? nil : event
            },
        ].compactMap(\.self)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hoverChange?.cancel()
    }

    func close() {
        browser.showsMainMenu = false
    }

    func run(_ row: MenuRow) {
        guard row.enabled else { return }
        close()
        if let action = row.action {
            action()
        } else if let item = row.item, let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    /// The menu's row `index` was clicked or chosen. A submenu opens now, without the hover's wait.
    func choose(_ index: Int) {
        hoverChange?.cancel()
        row = index
        if rows[index].opensSubmenu { open = index } else { run(rows[index]) }
    }

    // MARK: Pointer

    func hover(_ index: Int, inside: Bool) {
        guard inside else {
            if row == index, open != index { row = nil }
            return
        }
        row = index
        subrow = nil
        hoverChange?.cancel()
        guard open != index else { return }
        hoverChange = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard let self, !Task.isCancelled else { return }
            open = rows[index].opensSubmenu ? index : nil
        }
    }

    func hoverSubmenu(_ index: Int, inside: Bool) {
        if inside {
            hoverChange?.cancel()
            row = open
            subrow = index
        } else if subrow == index {
            subrow = nil
        }
    }

    /// A click outside closes the menu and goes no further, as with a system menu. Returns whether
    /// it took the click.
    private func click(_ event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView else { return false }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if panels[0].contains(point) || (open != nil && panels[1].contains(point)) { return false }
        close()
        return true
    }

    // MARK: Keyboard

    /// Arrows, Return, Space and Escape work the menu, and other plain keys go no further. Shortcuts
    /// pass through to the menu bar and close it. Returns whether it took the key.
    private func press(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            close()
            return false
        }
        switch event.keyCode {
        case 125: move(1)  // down
        case 126: move(-1)  // up
        case 123, 124: side()  // left, right
        case 36, 49, 76:  // return, space, enter
            if let subrow, subrows.indices.contains(subrow) {
                run(subrows[subrow])
            } else if let row {
                rows[row].opensSubmenu ? side() : choose(row)
            }
        case 53:  // esc
            if open != nil { leaveSubmenu() } else { close() }
        default: break
        }
        return true
    }

    private func move(_ offset: Int) {
        hoverChange?.cancel()
        if subrow != nil {
            subrow = MenuNavigation.step(from: subrow, by: offset, enabled: subrows.map(\.enabled))
        } else {
            row = MenuNavigation.step(from: row, by: offset, enabled: rows.map(\.enabled))
            open = nil
        }
    }

    /// The submenu sits to the left, so left goes into it, but right is what a Mac's menus use, so
    /// both do: into the highlighted row's submenu, or back out of the one you're in.
    private func side() {
        hoverChange?.cancel()
        if subrow != nil {
            leaveSubmenu()
        } else if let row, rows[row].opensSubmenu {
            open = row
            subrow = MenuNavigation.step(from: nil, by: 1, enabled: subrows.map(\.enabled))
        }
    }

    private func leaveSubmenu() {
        hoverChange?.cancel()
        open = nil
        subrow = nil
    }
}

/// Skylight's menu, under the ··· button at the end of the toolbar: a pane of glass over the page,
/// with a second one for a submenu.
struct SkylightMenu: View {
    @Environment(Browser.self) private var browser
    @State private var height: CGFloat = 0

    var body: some View {
        let showing = browser.showsMainMenu && browser.pages.fullscreenTabID == nil
        ZStack(alignment: .topTrailing) {
            Color.clear.allowsHitTesting(false)
            if showing {
                MenuPanels(browser: browser, height: height)
                    .padding(.top, MenuMetrics.margin)
                    .padding(.trailing, MenuMetrics.margin + 2)
                    .transition(Arrive(anchor: .topTrailing, scale: 0.96, rise: -4))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .motion(showing ? Motion.arrive : Motion.exit, value: showing)
    }
}

private enum MenuMetrics {
    static let margin: CGFloat = 6
    static let inset: CGFloat = 5
    static let rowHeight: CGFloat = 28
    static let divider: CGFloat = 9
    static let radius: CGFloat = 14
    static let width: CGFloat = 244

    /// How far down its panel the row `index` starts.
    static func top(of index: Int, in sections: [[MenuRow]]) -> CGFloat {
        var seen = 0, dividers = 0
        for section in sections where seen + section.count <= index {
            seen += section.count
            dividers += 1
        }
        return inset + CGFloat(index) * rowHeight + CGFloat(dividers) * divider
    }
}

private struct MenuPanels: View {
    let height: CGFloat
    private let browser: Browser
    @State private var session: MenuSession
    @State private var submenuHeight: CGFloat = 0

    init(browser: Browser, height: CGFloat) {
        self.browser = browser
        self.height = height
        _session = State(initialValue: MenuSession(browser: browser))
    }

    var body: some View {
        let sections = MenuContent.sections(browser)
        let rows = sections.flatMap(\.self)
        HStack(alignment: .top, spacing: 6) {
            if let open = session.open, rows.indices.contains(open) {
                MenuPanel(sections: rows[open].submenu, highlight: session.subrow,
                          choose: { session.run(session.subrows[$0]) },
                          hover: { session.hoverSubmenu($0, inside: $1) })
                    .frame(minWidth: 200, maxWidth: 300)
                    .fixedSize()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        session.panels[1] = $0
                        submenuHeight = $0.height
                    }
                    // Beside its row, as far as the window allows.
                    .padding(.top, max(0, min(MenuMetrics.top(of: open, in: sections) - MenuMetrics.inset,
                                              height - submenuHeight - 2 * MenuMetrics.margin)))
                    .id(open)
                    .transition(.opacity)
            }
            MenuPanel(sections: sections, highlight: session.row,
                      choose: { session.choose($0) },
                      hover: { session.hover($0, inside: $1) })
                .frame(width: MenuMetrics.width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.panels[0] = $0 }
        }
        .motion(Motion.feedback, value: session.open)
        .onAppear(perform: session.start)
        .onDisappear {
            session.stop()
            session.close()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in session.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in session.close() }
    }
}

/// One pane: the rows in their sections, with hairlines between. Rows are numbered across sections.
private struct MenuPanel: View {
    let sections: [[MenuRow]]
    let highlight: Int?
    let choose: (Int) -> Void
    let hover: (Int, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sections.indices, id: \.self) { section in
                if section > 0 {
                    Divider()
                        .padding(.horizontal, 9)
                        .frame(height: MenuMetrics.divider)
                }
                let first = sections[..<section].joined().count
                ForEach(Array(sections[section].enumerated()), id: \.element.id) { offset, row in
                    MenuRowView(row: row, highlighted: highlight == first + offset,
                                choose: { choose(first + offset) }, hover: { hover(first + offset, $0) })
                }
            }
        }
        .padding(MenuMetrics.inset)
        .glassEffect(.regular, in: .rect(cornerRadius: MenuMetrics.radius, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

private struct MenuRowView: View {
    let row: MenuRow
    let highlighted: Bool
    let choose: () -> Void
    let hover: (Bool) -> Void
    @Environment(Browser.self) private var browser

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 9) {
                icon.frame(width: 18)
                Text(row.title).lineLimit(1)
                Spacer(minLength: 18)
                if let keys = row.keys {
                    Text(keys).foregroundStyle(.secondary)
                }
                if row.opensSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(browser.preferences.density.rowFont)
            .padding(.horizontal, 9)
            .frame(height: MenuMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(MenuRowStyle(highlighted: highlighted))
        .disabled(!row.enabled)
        .onHover(perform: hover)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.icon {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case let .site(tab):
            Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: 16)
        }
    }
}

/// The row's box: the same as the toolbar's buttons, a shade of the text color.
private struct MenuRowStyle: ButtonStyle {
    let highlighted: Bool

    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, highlighted: highlighted) }

    private struct Look: View {
        let configuration: Configuration
        let highlighted: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .opacity(enabled ? 1 : 0.4)
                .background(.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.14 : highlighted ? 0.08 : 0),
                            in: .rect(cornerRadius: 9, style: .continuous))
        }
    }
}
