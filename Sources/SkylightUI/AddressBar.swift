import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// The address field in the toolbar, as in Safari: the site when you're reading, the full address
/// (selected) when you click it, with suggestions below while you type.
struct AddressField: View {
    @Environment(Browser.self) private var browser
    @Environment(AddressAnchor.self) private var anchor
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var bar = browser.commandBar
        let tab = browser.store.state.selectedTab
        let status = browser.selectedStatus
        let editing = bar.isPresented && bar.mode == .editCurrent
        // A new tab hasn't gone anywhere yet; the page behind the bar is empty.
        let newTab = bar.isPresented && bar.mode == .newTab

        // At rest, just where you are: the site, then the page's title. Click to type.
        HStack(spacing: 8) {
            if editing {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search or enter website name", text: $bar.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { bar.submit() }
                    .onKeyPress(.downArrow) { bar.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { bar.moveSelection(-1); return .handled }
                    .onKeyPress(.escape) { browser.dismissCommandBar(); return .handled }
            } else if newTab {
                Text("New Tab")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let tab {
                Text(Self.display(tab))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(1)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                Text(tab.shortTitle)
                    .foregroundStyle(.secondary)
                    .fadingTail()
                LoginKeyButton(url: tab.url)
            } else {
                Text("Search or enter website name")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(minWidth: 220, idealWidth: 520, maxWidth: 640, alignment: .leading)
        .background(editing ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
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
        .background { ViewProbe { anchor.field = $0 } }
        .contentShape(.rect)
        .onTapGesture { if !editing { browser.presentCommandBar(.editCurrent) } }
        .onChange(of: editing) { _, now in
            focused = now
            // ⌘L selects the address so typing replaces it.
            if now { DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
        }
        .onChange(of: focused) { _, now in
            // Clicking away (into the page, say) puts the address back.
            if !now, editing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !focused, browser.commandBar.mode == .editCurrent { browser.commandBar.dismiss() }
                }
            }
        }
        .accessibilityLabel("Address and search")
        // The address starts over the page, past the sidebar's edge, wherever the toolbar puts it.
        .padding(.leading, lead)
        .background { WindowXProbe { anchor.itemX = $0 } }
        .animation(Motion.resolved(Motion.travel), value: lead)
    }

    private var lead: CGFloat {
        let prefs = browser.preferences
        guard browser.showsSidebar, let x = anchor.itemX else { return 0 }
        return max(0, max(prefs.sidebarWidth, SidebarEdge.widths.lowerBound) + 6 - x)
    }

    static func display(_ tab: BrowserTab) -> String {
        guard let host = tab.url.host(percentEncoded: false) else { return tab.displayTitle }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Suggestions under the address field while you type, styled like a menu.
struct SuggestionsList: View {
    @Environment(Browser.self) private var browser
    @Environment(AddressAnchor.self) private var anchor

    var body: some View {
        let bar = browser.commandBar
        let items = bar.isPresented && bar.mode == .editCurrent ? bar.items : []
        if !items.isEmpty {
            // Read again when the window resizes, which moves the field.
            GeometryReader { geo in
                let field = anchor.fieldFrame(size: geo.size) ?? CGRect(x: (geo.size.width - 560) / 2, y: -6, width: 560, height: 0)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SuggestionRow(item: item, highlighted: index == bar.selection)
                            .onTapGesture { bar.submit(item) }
                            .onHover { if $0 { bar.selection = index } }
                    }
                }
                .padding(5)
                .frame(width: max(field.width, 360))
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .offset(x: max(field.minX, 8), y: field.maxY + 6)
            }
            .transition(.opacity)
        }
    }
}

/// Where the address field is. It sits in the toolbar and the suggestions over the page, which
/// are separate hosting views, so they meet in AppKit's coordinates.
@MainActor
@Observable
final class AddressAnchor {
    @ObservationIgnored weak var field: NSView?
    @ObservationIgnored weak var page: NSView?
    /// Where the address field's toolbar item starts, in the window.
    var itemX: CGFloat?

    /// The field's frame in the page's coordinates, y down; `size` is the page's.
    func fieldFrame(size: CGSize) -> CGRect? {
        guard let field, let page, field.window != nil, field.window === page.window else { return nil }
        let r = page.convert(field.bounds, from: field)
        return page.isFlipped ? r : CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }
}

/// An empty AppKit view, to find where a SwiftUI view is in the window. It reports itself each time
/// it joins a window, not when it's made: the toolbar rebuilds its items (hiding the sidebar does),
/// and a copy made for a layout that's gone would otherwise be the one remembered.
struct ViewProbe: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ view: Probe, context: Context) { view.found = found }

    final class Probe: NSView {
        var found: (NSView) -> Void

        init(found: @escaping (NSView) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { found(self) }
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
        HStack(spacing: 10) {
            Group {
                if item.kind == .tab || item.kind == .address {
                    Favicon(url: item.faviconURL, page: item.pageURL, title: item.title)
                } else {
                    Image(systemName: item.symbol)
                }
            }
            .frame(width: 16)
            Text(item.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.callout).foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
        .contentShape(.rect)
    }
}

/// ⌘T: a search field in the middle of the page with tabs, sites and commands under it. Type,
/// arrow to a row (or point at it), and press Return.
struct CommandPalette: View {
    @Environment(Browser.self) private var browser
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var bar = browser.commandBar
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Clicking outside closes it. Over a new tab's empty page there's nothing to dim.
                Color.black.opacity(bar.mode == .newTab ? 0 : 0.06)
                    .contentShape(.rect)
                    .onTapGesture { browser.dismissCommandBar() }

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: bar.mode == .split ? "rectangle.split.2x1" : "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        TextField(bar.mode == .split ? "Open beside this tab" : "Search or enter website name", text: $bar.query)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .focused($focused)
                            .onSubmit { bar.submit() }
                            .onKeyPress(.downArrow) { bar.moveSelection(1); return .handled }
                            .onKeyPress(.upArrow) { bar.moveSelection(-1); return .handled }
                            .onKeyPress(.escape) { browser.dismissCommandBar(); return .handled }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 54)

                    if !bar.items.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(bar.items.enumerated()), id: \.element.id) { index, item in
                                    PaletteRow(item: item, highlighted: index == bar.selection)
                                        .onTapGesture { bar.submit(item) }
                                        .onHover { if $0 { bar.selection = index } }
                                }
                            }
                            .padding(6)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: min(420, geo.size.height * 0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: min(640, geo.size.width - 48))
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .shadow(color: .black.opacity(0.2), radius: 30, y: 14)
                .padding(.top, max(40, geo.size.height * 0.18))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: focused) { _, now in
            if !now { DispatchQueue.main.async { focused = browser.commandBar.isPresented } }
        }
    }
}

private struct PaletteRow: View {
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
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            if highlighted {
                Image(systemName: "return").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}
