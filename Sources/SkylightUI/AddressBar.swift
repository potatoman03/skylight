import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// The address field in the toolbar. At rest it's where you are: the site, then the page's title.
/// Click it for the short address, selected, in a blue ring; type and the ring goes grey, with
/// suggestions around it. Click anywhere else and it's back to where you are.
struct AddressField: View {
    @Environment(Browser.self) private var browser
    @Environment(AddressAnchor.self) private var anchor

    var body: some View {
        let bar = browser.commandBar
        let tab = browser.store.state.selectedTab
        let status = browser.selectedStatus
        let editing = bar.isPresented && bar.mode == .editCurrent
        let typing = editing && bar.edited
        // A new tab hasn't gone anywhere yet.
        let newTab = browser.showsEmptyPage

        HStack(spacing: 8) {
            if editing {
                AddressEditor(bar: bar, anchor: anchor, query: bar.query, requests: bar.requests) { browser.dismissCommandBar() }
                if let tab {
                    HStack(spacing: 6) {
                        if typing { SearchMark() } else { SiteMenu(url: tab.url) }
                        BookmarkButton(tab: tab.id)
                    }
                    .padding(.trailing, 4)
                }
            } else if newTab {
                Text("New Tab")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let tab {
                HStack(spacing: 5) {
                    if Self.isLocal(tab.url) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.display(tab))
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                Text(tab.shortTitle)
                    .foregroundStyle(.secondary)
                    .fadingTail()
                AutofillButton(url: tab.url)
                LoginKeyButton(url: tab.url)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .frame(minWidth: 220, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(typing ? AnyShapeStyle(.separator) : AnyShapeStyle(.tint), lineWidth: typing ? 1 : 2)
                .opacity(editing ? 1 : 0)
        }
        // Loading shows as a hairline under the address.
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Capsule()
                    .fill(.tint)
                    .frame(width: geo.size.width * max(status.progress, 0.05), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(status.isLoading && !editing && !newTab ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: status.progress)
            }
            .allowsHitTesting(false)
        }
        .background { ViewProbe(found: { anchor.addField($0) }, moved: { anchor.moved() }) }
        .contentShape(.rect)
        .onTapGesture { if !editing { browser.presentCommandBar(.editCurrent) } }
        .onChange(of: editing) { _, now in
            // Done with the address, the keyboard goes back to the page unless another field took it.
            if !now { DispatchQueue.main.async { if !(NSApp.keyWindow?.firstResponder is NSText) { browser.pages.focusVisiblePage() } } }
        }
        .accessibilityLabel("Address and search")
        // The address starts over the page, past the sidebar's edge, wherever the toolbar puts it.
        .padding(.leading, lead)
        .background { WindowXProbe { anchor.itemX = $0 } }
        .animation(Motion.resolved(Motion.sidebar), value: lead)
    }

    private var lead: CGFloat {
        let prefs = browser.preferences
        guard browser.showsSidebar, let x = anchor.itemX else { return 0 }
        return max(0, max(prefs.sidebarWidth, SidebarEdge.widths.lowerBound) + 6 - x)
    }

    static func display(_ tab: BrowserTab) -> String {
        guard let host = tab.url.host(percentEncoded: false) else { return tab.displayTitle }
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + (tab.url.port.map { ":\($0)" } ?? "")
    }

    /// Something running on this machine or next to it, not a site.
    private static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
            || host.hasSuffix(".localhost") || host.hasSuffix(".local")
    }
}

/// The address as you edit it. It's an AppKit field because SwiftUI's focus can't do what this needs:
/// the toolbar can hold more than one copy of the field and only the one on screen may take the
/// keyboard, and clicking a button or the sidebar never takes it from the field at all.
private struct AddressEditor: NSViewRepresentable {
    let bar: CommandBarModel
    let anchor: AddressAnchor
    let query: String
    let requests: Int
    let cancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(bar: bar, cancel: cancel) }

    func makeNSView(context: Context) -> Field {
        let field = Field(anchor: anchor, bar: bar)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search or enter website name"
        field.stringValue = query
        field.requests = requests
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        if field.stringValue != query { field.stringValue = query }
        // ⌘L again while you're here starts over.
        if field.requests != requests {
            field.requests = requests
            field.take()
        }
    }

    final class Field: NSTextField {
        private let anchor: AddressAnchor
        private let bar: CommandBarModel
        var requests = 0
        private var clicks: Any?

        init(anchor: AddressAnchor, bar: CommandBarModel) {
            self.anchor = anchor
            self.bar = bar
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                take()
            } else if let clicks {
                NSEvent.removeMonitor(clicks)
                self.clicks = nil
            }
        }

        /// Gets the keyboard if this is the copy on screen, once it has its place in the toolbar. An
        /// address you haven't touched is selected, so typing replaces it.
        func take(tries: Int = 12) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self, let window = self.window else { return }
                guard self.anchor.holds(self) else {
                    if tries > 0 { self.take(tries: tries - 1) }
                    return
                }
                window.makeKey()
                if self.currentEditor() == nil { window.makeFirstResponder(self) }
                if self.bar.edited {
                    self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
                } else {
                    self.currentEditor()?.selectAll(nil)
                }
                self.watchClicks()
            }
        }

        /// A click anywhere else is done with the address, wherever it lands. Most of the window
        /// never takes the keyboard, so the field wouldn't otherwise know.
        private func watchClicks() {
            guard clicks == nil else { return }
            clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                if let self, !self.anchor.owns(event) { self.bar.dismiss() }
                return event
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let bar: CommandBarModel
        private let cancel: @MainActor () -> Void

        init(bar: CommandBarModel, cancel: @escaping @MainActor () -> Void) {
            self.bar = bar
            self.cancel = cancel
        }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { bar.query = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)): bar.moveSelection(1)
            case #selector(NSResponder.moveUp(_:)): bar.moveSelection(-1)
            case #selector(NSResponder.cancelOperation(_:)): cancel()
            case #selector(NSResponder.insertNewline(_:)): bar.submit()
            default: return false
            }
            return true
        }

        /// A click away has already put the address back. A page that's loading doesn't get to
        /// take the keyboard while you're typing.
        func controlTextDidEndEditing(_ note: Notification) {
            guard bar.isPresented, bar.mode == .editCurrent, let field = note.object as? Field else { return }
            field.take()
        }
    }
}

/// The site's controls, at the end of an address you haven't touched.
private struct SiteMenu: View {
    let url: URL
    @Environment(Browser.self) private var browser

    var body: some View {
        let secure = url.scheme == "https"
        Menu {
            Text(secure ? "Connection is secure" : "Connection isn't secure")
            Divider()
            Button("Copy Link") { browser.copyLink() }
            Button("Developer Tools") { browser.showDeveloperTools() }
        } label: {
            Image(systemName: secure ? "slider.horizontal.3" : "info.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .help("Site details")
    }
}

/// Where Return is about to go: the search engine, or a globe for an address.
private struct SearchMark: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let prefs = browser.preferences
        Group {
            if browser.commandBar.items.first?.kind == .search {
                Favicon(url: nil, page: URL(string: prefs.searchTemplate), title: prefs.searchEngine.name)
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct BookmarkButton: View {
    let tab: TabID
    @Environment(Browser.self) private var browser

    var body: some View {
        let favorite = browser.store.state.isFavorite(tab)
        Button {
            animate(Motion.travel) { _ = browser.store.send(.toggleFavorite(tab)) }
        } label: {
            Image(systemName: favorite ? "bookmark.fill" : "bookmark")
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(favorite ? "Remove from Favorites" : "Add to Favorites")
    }
}

/// Suggestions while you type, as one panel with the address field: it starts behind the field
/// (which sits in the toolbar, over it) and reaches just past it on every side.
struct SuggestionsList: View {
    @Environment(Browser.self) private var browser
    @Environment(AddressAnchor.self) private var anchor

    /// How far the panel reaches past the field on each side.
    private static let margin: CGFloat = 6

    var body: some View {
        let bar = browser.commandBar
        let items = bar.isPresented && bar.mode == .editCurrent ? bar.suggestions : []
        if !items.isEmpty {
            // Read again when the window resizes, which moves the field.
            GeometryReader { geo in
                let field = anchor.fieldFrame(size: geo.size) ?? CGRect(x: (geo.size.width - 560) / 2, y: -34, width: 560, height: 32)
                let m = Self.margin
                VStack(spacing: 0) {
                    // The field shows through here.
                    Color.clear.frame(height: field.height + 9)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SuggestionRow(item: item, highlighted: index == bar.selection)
                            .onTapGesture { bar.submit(item) }
                            .onHover { if $0 { bar.selection = index } }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, m)
                .frame(width: max(field.width, 360) + 2 * m)
                .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .background { ViewProbe(found: { anchor.panel = $0 }, moved: {}) }
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .offset(x: max(field.minX - m, 4), y: field.minY - m)
            }
            .transition(.opacity)
        }
    }
}

/// Where the address field is. It sits in the toolbar and the suggestions over the page, which
/// are separate hosting views, and in full screen separate windows, so they meet on the screen.
@MainActor
@Observable
final class AddressAnchor {
    /// Every copy of the field the toolbar has made. It rebuilds its items (hiding the sidebar
    /// does) and can keep an old copy in the window, out of sight.
    @ObservationIgnored private var fields = NSHashTable<NSView>.weakObjects()
    @ObservationIgnored weak var page: NSView?
    /// The suggestions.
    @ObservationIgnored weak var panel: NSView?
    /// Where the address field's toolbar item starts, in the window.
    var itemX: CGFloat?
    /// Makes whoever reads the field's frame read it again.
    private var moves = 0

    func addField(_ view: NSView) {
        fields.add(view)
        // A toolbar item keeps to its ideal width unless it hugs its content this loosely. Then the
        // toolbar gives it the room left over, and it never crowds the buttons out. The item
        // arrives after its view, and a rebuilt toolbar makes a new one.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            let item = view.window?.toolbar?.items.first { $0.view.map(view.isDescendant(of:)) ?? false }
            item?.view?.setContentHuggingPriority(.init(1), for: .horizontal)
        }
    }

    /// The field or the page moved, which they do on every frame of an animation. AppKit has the
    /// whole new layout once this pass is over.
    func moved() {
        DispatchQueue.main.async { self.moves += 1 }
    }

    /// The field on screen: the one you're typing in, else the widest one showing, since the old
    /// copies are left narrower.
    private var field: NSView? {
        let showing = fields.allObjects.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        for view in showing {
            guard let editor = view.window?.firstResponder as? NSText else { continue }
            // All of what's being typed in: an old, narrower copy can sit over part of it.
            let r = editor.convert(editor.visibleRect, to: nil)
            if view.convert(view.bounds, to: nil).insetBy(dx: -2, dy: -2).contains(r) { return view }
        }
        return showing.max { $0.bounds.width < $1.bounds.width }
    }

    /// Whether this view is in the field on screen.
    func holds(_ view: NSView) -> Bool {
        guard let field, field.window == view.window else { return false }
        let r = view.convert(view.bounds, to: nil)
        return !r.isEmpty && field.convert(field.bounds, to: nil).insetBy(dx: -2, dy: -2).contains(r)
    }

    /// Whether a click landed on the field or its suggestions.
    func owns(_ event: NSEvent) -> Bool {
        guard let point = event.window?.convertPoint(toScreen: event.locationInWindow) else { return false }
        return [field, panel].contains { view in
            guard let view, let window = view.window else { return false }
            return window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }
    }

    /// The field's frame in the page's coordinates, y down; `size` is the page's.
    func fieldFrame(size: CGSize) -> CGRect? {
        _ = moves
        guard let field, let page, let fieldWindow = field.window, let pageWindow = page.window else { return nil }
        let onScreen = fieldWindow.convertToScreen(field.convert(field.bounds, to: nil))
        let r = page.convert(pageWindow.convertFromScreen(onScreen), from: nil)
        return page.isFlipped ? r : CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }
}

/// An empty AppKit view, to find where a SwiftUI view is in the window. It reports itself each time
/// it joins a window, not when it's made: the toolbar rebuilds its items (hiding the sidebar does),
/// and a copy made for a layout that's gone would otherwise be the one remembered.
struct ViewProbe: NSViewRepresentable {
    let found: (NSView) -> Void
    let moved: () -> Void

    func makeNSView(context: Context) -> Probe { Probe(found: found, moved: moved) }

    func updateNSView(_ view: Probe, context: Context) {
        view.found = found
        view.moved = moved
    }

    final class Probe: NSView {
        var found: (NSView) -> Void
        var moved: () -> Void

        init(found: @escaping (NSView) -> Void, moved: @escaping () -> Void) {
            self.found = found
            self.moved = moved
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { found(self) }
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            moved()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            moved()
        }
    }
}

/// Reports where a view starts in its window, again whenever the window resizes or goes full screen.
struct WindowXProbe: NSViewRepresentable {
    let changed: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe(changed: changed) }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed }

    final class Probe: NSView {
        var changed: (CGFloat) -> Void
        private var last: CGFloat?
        private var observers: [NSObjectProtocol] = []

        init(changed: @escaping (CGFloat) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        /// After layout settles, so SwiftUI state doesn't change mid-layout.
        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                let x = self.convert(self.bounds, to: nil).minX.rounded()
                if x != self.last { self.last = x; self.changed(x) }
            }
        }
    }
}

private struct SuggestionRow: View {
    let item: CommandItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if item.kind == .tab || item.kind == .address {
                    Favicon(url: item.faviconURL, page: item.pageURL, title: item.title, size: 18)
                } else {
                    Image(systemName: item.symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            HStack(spacing: 4) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text("- \(subtitle)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .background(.primary.opacity(highlighted ? 0.09 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }
}

/// An empty page's search field, in the middle of it, with tabs, sites and commands under it. Type,
/// arrow to a row (or point at it), and press Return.
struct CommandPalette: View {
    @Environment(Browser.self) private var browser
    @FocusState private var focused: Bool

    private static let fieldHeight: CGFloat = 54

    var body: some View {
        @Bindable var bar = browser.commandBar
        // It stays on an empty page when you're not typing in it.
        let emptyPage = !bar.isPresented || bar.mode == .newTab
        let split = bar.isPresented && bar.mode == .split
        let items = bar.isPresented ? bar.items : []
        // Just the field, in the middle of the page.
        let bare = emptyPage && items.isEmpty
        GeometryReader { geo in
            let top = emptyPage ? geo.size.height * 0.42 - Self.fieldHeight / 2 : max(40, geo.size.height * 0.18)
            ZStack(alignment: .top) {
                // Clicking outside closes it. Over a new tab's empty page there's nothing to dim.
                Color.black.opacity(emptyPage ? 0 : 0.06)
                    .contentShape(.rect)
                    .onTapGesture { browser.dismissCommandBar() }

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: split ? "rectangle.split.2x1" : "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        TextField(split ? "Open beside this tab" : "Search or enter website name", text: $bar.query)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .focused($focused)
                            .onSubmit { bar.submit() }
                            .onKeyPress(.downArrow) { bar.moveSelection(1); return .handled }
                            .onKeyPress(.upArrow) { bar.moveSelection(-1); return .handled }
                            .onKeyPress(.escape) { browser.dismissCommandBar(); return .handled }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: Self.fieldHeight)

                    if !items.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    PaletteRow(item: item, highlighted: index == bar.selection)
                                        .onTapGesture { bar.submit(item) }
                                        .onHover { if $0 { bar.selection = index } }
                                }
                            }
                            .padding(6)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: min(420, geo.size.height - top - Self.fieldHeight - 24))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: min(640, geo.size.width - 48))
                .glassEffect(bare ? .clear : .regular, in: .rect(cornerRadius: bare ? Self.fieldHeight / 2 : 20))
                // Asked for while it's already here, it shows it heard.
                .keyframeAnimator(initialValue: 1.0, trigger: bar.requests) { view, scale in
                    view.scaleEffect(Motion.reduceMotion ? 1 : scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.025, duration: 0.1, spring: .snappy)
                        SpringKeyframe(1, duration: 0.24, spring: .snappy)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 30, y: 14)
                .padding(.top, top)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        .onAppear {
            // You land on an empty page ready to type, however you got there.
            if !bar.isPresented { browser.presentCommandBar(.newTab) }
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, now in
            if now {
                if !browser.commandBar.isPresented { browser.presentCommandBar(.newTab) }
            } else {
                DispatchQueue.main.async {
                    guard browser.commandBar.isPresented, browser.commandBar.mode != .editCurrent else { return }
                    // Pages don't get to take the keyboard from it, but you might be renaming a Space.
                    if NSApp.keyWindow?.firstResponder is NSText { browser.dismissCommandBar() } else { focused = true }
                }
            }
        }
        .onChange(of: bar.isPresented) { _, now in
            focused = now
            if !now { bar.query = "" }
        }
    }
}

private struct PaletteRow: View {
    @Environment(\.onTint) private var onTint
    let item: CommandItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.kind == .tab || item.kind == .address {
                    Favicon(url: item.faviconURL, page: item.pageURL, title: item.title)
                } else {
                    Image(systemName: item.symbol)
                }
            }
            .frame(width: 18)
            Text(item.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.callout)
                    .foregroundStyle(highlighted ? AnyShapeStyle(onTint.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            if highlighted {
                Image(systemName: "return").font(.caption.weight(.semibold)).foregroundStyle(onTint.opacity(0.85))
            }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(onTint) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}
