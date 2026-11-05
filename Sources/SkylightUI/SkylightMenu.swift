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
        // It opens upward, so the commonest rows are nearest the button.
        return [
            [
                MenuRow("Profiles", "person.crop.circle") { browser.openSettings("profiles") },
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
                MenuRow("Keyboard Shortcuts", "command", "showShortcuts:"),
                MenuRow("Settings", "gearshape", "showSettings:"),
            ],
            [
                MenuRow("New Tab", "plus", "newTab:"),
                MenuRow("New Space", "square.stack", "newSpace:"),
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
    /// The row `hoverChange` will settle on.
    @ObservationIgnored private var settling: Int?
    /// Where the pointer last was on the open row: the tip of the funnel to its submenu.
    @ObservationIgnored private var apex: CGPoint?
    /// The mouse is down and has reached a row, so letting go chooses what's under it.
    @ObservationIgnored private var dragging = false
    /// The row the mouse went down on, whose own button handles letting go on it.
    @ObservationIgnored private var pressed: Int?

    /// How long the pointer rests on a row before its submenu opens or goes.
    private static let hoverDelay = Duration.milliseconds(130)
    /// How long the pointer can stop inside the funnel before the row under it wins.
    private static let funnelDelay = Duration.milliseconds(300)

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
            // SwiftUI's hover stops while the mouse is down, so one tracker serves both.
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved(event) }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                MainActor.assumeIsolated { self?.mouseUp(event) }
                return event
            },
        ].compactMap(\.self)
        (NSApp.keyWindow ?? NSApp.mainWindow)?.acceptsMouseMovedEvents = true
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        cancelHover()
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
        cancelHover()
        row = index
        if rows[index].opensSubmenu { open = index } else { run(rows[index]) }
    }

    // MARK: Pointer

    private func point(of event: NSEvent) -> CGPoint? {
        guard let content = event.window?.contentView else { return nil }
        return CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
    }

    private func mainRow(at point: CGPoint) -> Int? {
        guard panels[0].contains(point) else { return nil }
        return MenuNavigation.row(at: point.y - panels[0].minY, sections: MenuContent.sections(browser).map(\.count),
                                  inset: MenuMetrics.inset, rowHeight: MenuMetrics.rowHeight, divider: MenuMetrics.divider)
    }

    private func submenuRow(at point: CGPoint) -> Int? {
        guard open != nil, panels[1].contains(point), let open else { return nil }
        return MenuNavigation.row(at: point.y - panels[1].minY, sections: rows[open].submenu.map(\.count),
                                  inset: MenuMetrics.inset, rowHeight: MenuMetrics.rowHeight, divider: MenuMetrics.divider)
    }

    private func pointerMoved(_ event: NSEvent) {
        guard let point = point(of: event) else { return }
        let held = event.type == .leftMouseDragged
        if open != nil, panels[1].contains(point) {
            cancelHover()
            row = open
            subrow = submenuRow(at: point).flatMap { subrows[$0].enabled ? $0 : nil }
            if held { dragging = true }
            return
        }
        subrow = nil
        guard let index = mainRow(at: point) else {
            if open == nil { row = nil }
            if settling != open { cancelHover() }
            return
        }
        if held { dragging = true }
        if index == open {
            cancelHover()
            row = index
            apex = point
        } else if open != nil, let apex, panels[1].width > 0,
                  MenuNavigation.isInFunnel(point, from: apex, toEdgeAtX: panels[1].minX, top: panels[1].minY, bottom: panels[1].maxY) {
            // On the way to the submenu. It only gives way if the pointer stops here.
            settle(on: index, after: Self.funnelDelay, restart: true)
        } else {
            row = index
            settle(on: index, after: Self.hoverDelay, restart: false)
            if rows[index].opensSubmenu, open == nil { apex = point }
        }
    }

    /// In a moment, `index` becomes the highlighted row and shows its submenu, if any. Moving
    /// within a row doesn't start the wait again, unless `restart`.
    private func settle(on index: Int, after delay: Duration, restart: Bool) {
        guard restart || settling != index else { return }
        hoverChange?.cancel()
        settling = index
        hoverChange = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            settling = nil
            row = index
            open = rows[index].opensSubmenu ? index : nil
        }
    }

    private func cancelHover() {
        hoverChange?.cancel()
        settling = nil
    }

    /// Letting go after dragging over the menu chooses what's under the pointer, as with a system
    /// menu. A row's own button handles a plain click.
    private func mouseUp(_ event: NSEvent) {
        defer {
            dragging = false
            pressed = nil
        }
        guard dragging, let point = point(of: event) else { return }
        if let index = submenuRow(at: point) {
            run(subrows[index])
        } else if let index = mainRow(at: point) {
            if index != pressed { choose(index) }
        } else if !panels[1].contains(point) || open == nil {
            close()
        }
    }

    /// A click outside closes the menu and goes no further, as with a system menu. Returns whether
    /// it took the click.
    private func click(_ event: NSEvent) -> Bool {
        guard let point = point(of: event) else { return false }
        if panels[0].contains(point) || (open != nil && panels[1].contains(point)) {
            pressed = mainRow(at: point)
            return false
        }
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
        case 123: if subrow != nil { leaveSubmenu() }  // left
        case 124: enterSubmenu()  // right
        case 36, 49, 76:  // return, space, enter
            if let subrow, subrows.indices.contains(subrow) {
                run(subrows[subrow])
            } else if let row {
                rows[row].opensSubmenu ? enterSubmenu() : choose(row)
            }
        case 53:  // esc
            if open != nil { leaveSubmenu() } else { close() }
        default: break
        }
        return true
    }

    private func move(_ offset: Int) {
        cancelHover()
        if subrow != nil {
            subrow = MenuNavigation.step(from: subrow, by: offset, enabled: subrows.map(\.enabled))
        } else {
            row = MenuNavigation.step(from: row, by: offset, enabled: rows.map(\.enabled))
            open = nil
        }
    }

    private func enterSubmenu() {
        cancelHover()
        guard subrow == nil, let row, rows[row].opensSubmenu else { return }
        open = row
        apex = nil
        subrow = MenuNavigation.step(from: nil, by: 1, enabled: subrows.map(\.enabled))
    }

    private func leaveSubmenu() {
        cancelHover()
        open = nil
        subrow = nil
    }
}

/// The button at the left of the Space bar: the Space you're in, and a chevron. It opens on press,
/// like a Mac's menus, so you can drag straight into the menu and let go on a row. The action is
/// for VoiceOver and Full Keyboard Access, which don't press.
struct SkylightMenuButton: View {
    @Environment(Browser.self) private var browser
    @State private var openedByPress = false

    var body: some View {
        let space = browser.store.state.activeSpace
        Button {
            if !openedByPress { browser.toggleMainMenu() }
            openedByPress = false
        } label: {
            HStack(spacing: 4) {
                SpaceIcon(icon: space.icon, name: space.name, size: 10)
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent(space.hue), in: .circle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(MenuButtonStyle { pressed in
            guard pressed, !browser.showsMainMenu else { return }
            openedByPress = true
            browser.toggleMainMenu()
        })
        .help("Menu")
        .accessibilityLabel("Menu")
    }
}

/// A box that shows on hover and dips when pressed, like the toolbar's buttons.
private struct MenuButtonStyle: ButtonStyle {
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration).onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }

    private struct Look: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
                .animation(Motion.resolved(Motion.feedback), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Skylight's menu, above the Space button: a pane of glass in the window's
/// top left corner, with a second one to its right for a submenu.
struct SkylightMenu: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let showing = browser.showsMainMenu && browser.pages.fullscreenTabID == nil
        ZStack(alignment: .bottomLeading) {
            Color.clear.allowsHitTesting(false)
            if showing {
                MenuPanels(browser: browser)
                    .padding(.bottom, MenuMetrics.bottom)
                    .padding(.leading, MenuMetrics.margin)
                    .transition(.opacity)
            }
        }
        .motion(Motion.feedback, value: showing)
    }
}

enum MenuMetrics {
    /// Around the menu in the sidebar, and between the menu and a submenu.
    static let margin: CGFloat = 8
    static let inset: CGFloat = 5
    static let rowHeight: CGFloat = 28
    static let divider: CGFloat = 9
    static let radius: CGFloat = 14
    static let width: CGFloat = 244
    /// From the window's bottom edge: clear of the Space bar and its button.
    static let bottom: CGFloat = 38

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
    private let browser: Browser
    @State private var session: MenuSession
    @State private var submenuHeight: CGFloat = 0

    init(browser: Browser) {
        self.browser = browser
        _session = State(initialValue: MenuSession(browser: browser))
    }

    var body: some View {
        let sections = MenuContent.sections(browser)
        let rows = sections.flatMap(\.self)
        MenuPanel(sections: sections, highlight: session.row, choose: { session.choose($0) })
            // Inside the sidebar, so its edge doesn't run through the glass.
            .frame(width: min(MenuMetrics.width, max(browser.preferences.sidebarWidth, SidebarEdge.widths.lowerBound) - 2 * MenuMetrics.margin))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.panels[0] = $0 }
            // Hung off the menu's right edge, outside its layout, so the menu stays put. It appears at
            // once, like a Mac's.
            .overlay(alignment: .topTrailing) {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .topLeading) {
                        if let open = session.open, rows.indices.contains(open) {
                            MenuPanel(sections: rows[open].submenu, highlight: session.subrow,
                                      choose: { session.run(session.subrows[$0]) })
                                .frame(minWidth: 200, maxWidth: 300)
                                .fixedSize()
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    session.panels[1] = $0
                                    submenuHeight = $0.height
                                }
                                // Level with its row, without passing the menu's foot.
                                .offset(x: MenuMetrics.margin,
                                        y: min(MenuMetrics.top(of: open, in: sections) - MenuMetrics.inset,
                                               session.panels[0].height - submenuHeight))
                        }
                    }
            }
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
                                choose: { choose(first + offset) })
                }
            }
        }
        .padding(MenuMetrics.inset)
        .glassEffect(.regular, in: .rect(cornerRadius: MenuMetrics.radius, style: .continuous))
        // A hairline, so the pane keeps its edge against a dark sidebar.
        .overlay {
            RoundedRectangle(cornerRadius: MenuMetrics.radius, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

private struct MenuRowView: View {
    let row: MenuRow
    let highlighted: Bool
    let choose: () -> Void
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
