import AppKit
import SkylightBrowser
import SkylightCore
import SkylightEngine
import SwiftUI

/// The page, edge to edge. A split shows its panes side by side (or stacked) with a hairline
/// between them that you drag to resize, and a grip on each pane to move it.
struct ContentArea: View {
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @Environment(AddressAnchor.self) private var anchor

    var body: some View {
        let state = browser.store.state
        let tab = state.selectedTab
        let split = tab.flatMap { state.activeSpace.split(containing: $0.id) }

        GeometryReader { geo in
            let layout = PaneLayout(split: split, focused: tab?.id, size: geo.size, gap: PaneStyle.gap)
            ZStack(alignment: .topLeading) {
                // A split's panes sit on the window's backdrop, which shows around them.
                if !layout.isSplit { Color(nsColor: .windowBackgroundColor) }
                PageHost(view: browser.pages.hostView)

                if tab == nil {
                    ContentUnavailableView {
                        Label("No Tab Open", systemImage: "safari")
                    } description: {
                        Text("Search or enter a website name in the address field.")
                    } actions: {
                        Button("New Tab") { browser.presentCommandBar(.newTab) }
                            .keyboardShortcut("t")
                    }
                    .opacity(browser.commandBar.isPresented ? 0 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }

                if let split, layout.isSplit {
                    PaneChrome(split: split, layout: layout)
                        // The pages move at once; their dividers and grips must move with them.
                        .transaction { $0.animation = nil }
                }

                // The engine's view would take a dropped tab as text, so a drag gets a target on top.
                if drag.active != nil, tab != nil {
                    PageDropTarget(layout: layout)
                }
            }
            .coordinateSpace(.named(PaneLayout.space))
        }
        .background { ViewProbe { anchor.page = $0 } }
        .overlay(alignment: .topLeading) { SuggestionsList() }
        .overlay {
            let bar = browser.commandBar
            ZStack {
                // A new tab opens on an empty page, not over the one you were reading.
                if bar.isPresented, bar.mode == .newTab {
                    Color(nsColor: .textBackgroundColor).transition(.opacity)
                }
                if bar.isPresented, bar.mode != .editCurrent { CommandPalette() }
            }
        }
        .animation(browser.commandBar.isPresented ? Motion.resolved(Motion.arrive) : Motion.resolved(Motion.exit),
                   value: browser.commandBar.isPresented && browser.commandBar.mode != .editCurrent)
        .overlay(alignment: .bottom) { ToastView() }
        .modifier(PromptAlerts())
    }
}

/// What's drawn over a split's pages: the focus outline, the dividers and each pane's grip.
private struct PaneChrome: View {
    let split: TabSplit
    let layout: PaneLayout
    @Environment(Browser.self) private var browser

    var body: some View {
        ZStack(alignment: .topLeading) {
            if browser.preferences.highlightFocusedPane {
                let frame = layout.focusedFrame
                RoundedRectangle(cornerRadius: PaneStyle.radius, style: .continuous)
                    .strokeBorder(.tint.opacity(0.8), lineWidth: 2)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
            }
            ForEach(layout.dividers, id: \.index) { divider in
                SplitDivider(split: split, divider: divider, length: layout.length)
            }
            ForEach(layout.panes, id: \.tab) { pane in
                PaneGrip(tab: pane.tab, split: split, focused: pane.tab == layout.focused)
                    .position(x: pane.frame.midX, y: pane.frame.minY + 12)
            }
        }
    }
}

/// Hosts the coordinator's page container. SwiftUI never re-creates it, so pages keep running.
struct PageHost: NSViewRepresentable {
    let view: PageHostView

    func makeNSView(context: Context) -> PageHostView { view }
    func updateNSView(_ view: PageHostView, context: Context) {}
}

/// Where each pane goes. Mirrors the page host's layout, so dividers and grips line up with pages.
struct PaneLayout {
    struct Pane { let tab: TabID; let frame: CGRect }
    struct Divider { let index: Int; let frame: CGRect }

    static let space = "skylight.content"

    let panes: [Pane]
    let focused: TabID?
    let axis: TabSplit.Axis
    /// The length along the split, less the gaps: what fractions are shares of.
    let length: CGFloat
    let gap: CGFloat
    let size: CGSize

    init(split: TabSplit?, focused: TabID?, size: CGSize, gap: CGFloat) {
        self.focused = focused
        self.gap = gap
        self.size = size
        axis = split?.axis ?? .horizontal
        if let split, split.tabs.count > 1 {
            panes = zip(split.tabs, PaneStyle.frames(of: split, in: size, gap: gap)).map(Pane.init)
            let extent = split.axis == .horizontal ? size.width : size.height
            length = max(1, extent - PaneStyle.inset * 2 - gap * CGFloat(split.tabs.count - 1))
        } else {
            panes = focused.map { [Pane(tab: $0, frame: CGRect(origin: .zero, size: size))] } ?? []
            length = max(1, size.width)
        }
    }

    var isSplit: Bool { panes.count > 1 }

    var focusedFrame: CGRect { panes.first { $0.tab == focused }?.frame ?? panes.first?.frame ?? .zero }

    /// The gaps between panes, widened so they're easy to grab.
    var dividers: [Divider] {
        guard isSplit else { return [] }
        let reach: CGFloat = 9
        return panes.dropLast().enumerated().map { i, pane in
            let f = pane.frame
            let frame = axis == .horizontal
                ? CGRect(x: f.maxX + gap / 2 - reach / 2, y: f.minY, width: reach, height: f.height)
                : CGRect(x: f.minX, y: f.maxY + gap / 2 - reach / 2, width: f.width, height: reach)
            return Divider(index: i, frame: frame)
        }
    }

    /// Where a tab dropped at `point` would go, if it can go there.
    func dropTarget(at point: CGPoint, dragging payload: TabDragSession.Payload, state: BrowserState) -> (tab: TabID, edge: SplitEdge)? {
        let id = payload.id
        guard let pane = panes.first(where: { $0.frame.contains(point) }) ?? panes.first else { return nil }
        var target = pane.tab
        if target == id {
            // The tab on screen dragged over its own page goes beside the tab you had before it.
            guard panes.count == 1, let previous = Self.previousTab(before: id, in: state) else { return nil }
            target = previous
        }
        let split = state.activeSpace.split(containing: target)
        let inSplit = split?.tabs.contains(id) == true
        // Built-in pages can't share the window.
        if state.tabs[id]?.url.isSkylightPage == true || state.tabs[target]?.url.isSkylightPage == true { return nil }
        if let split, !inSplit, split.tabs.count >= TabSplit.maxPanes { return nil }
        // A sidebar row that is a whole split can't join another.
        if payload.source == .row, !inSplit, state.space(containing: id)?.group(of: id).count ?? 1 > 1 { return nil }
        let f = pane.frame
        let x = (point.x - f.minX) / max(f.width, 1), y = (point.y - f.minY) / max(f.height, 1)
        if let split {
            return split.axis == .horizontal ? (target, x < 0.5 ? .leading : .trailing) : (target, y < 0.5 ? .top : .bottom)
        }
        // Side by side is the usual case: it wins unless the pointer is clearly near the top or bottom.
        let edges: [(SplitEdge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y * 1.6), (.bottom, (1 - y) * 1.6)]
        return (target, edges.min { $0.1 < $1.1 }!.0)
    }

    /// The Space's most recently shown tab other than `id` that can share the window: not a
    /// favorite (splitting would take it out of Favorites), in no split, and not a built-in page.
    static func previousTab(before id: TabID, in state: BrowserState) -> TabID? {
        let space = state.activeSpace
        return (space.pinned + space.today)
            .filter { $0 != id && space.split(containing: $0) == nil && state.tabs[$0]?.url.isSkylightPage == false }
            .max { (state.tabs[$0]?.lastActiveAt ?? .distantPast) < (state.tabs[$1]?.lastActiveAt ?? .distantPast) }
    }

    /// The panes a drop would make, each where it would be: what goes where. Mirrors the reducer:
    /// a new pane takes half of the one it lands beside; a pane moved within its split keeps its share.
    func arrangement(placing id: TabID, beside target: TabID, edge: SplitEdge, state: BrowserState) -> [Pane] {
        var split: TabSplit
        if var current = state.activeSpace.split(containing: target) {
            if let from = current.tabs.firstIndex(of: id) {
                let fraction = current.fractions.remove(at: from)
                current.tabs.remove(at: from)
                let index = (current.tabs.firstIndex(of: target) ?? 0) + (edge.isAfter ? 1 : 0)
                current.tabs.insert(id, at: index)
                current.fractions.insert(fraction, at: index)
            } else {
                let pane = current.tabs.firstIndex(of: target) ?? 0
                let half = current.fractions[pane] / 2
                current.fractions[pane] = half
                let index = edge.isAfter ? pane + 1 : pane
                current.tabs.insert(id, at: index)
                current.fractions.insert(half, at: index)
            }
            current.normalize()
            split = current
        } else {
            split = TabSplit(tabs: edge.isAfter ? [target, id] : [id, target], axis: edge.axis)
        }
        return zip(split.tabs, PaneStyle.frames(of: split, in: size)).map(Pane.init)
    }
}

/// Drag to resize the panes either side; double-click to make them equal.
private struct SplitDivider: View {
    let split: TabSplit
    let divider: PaneLayout.Divider
    let length: CGFloat
    @Environment(Browser.self) private var browser
    @State private var start: TabSplit?

    var body: some View {
        let horizontal = split.axis == .horizontal
        Color.clear
            .contentShape(.rect)
            .frame(width: divider.frame.width, height: divider.frame.height)
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(PaneLayout.space))
                    .onChanged { value in
                        if start == nil { start = browser.store.state.activeSpace.split(containing: split.tabs[0]) ?? split }
                        guard var next = start else { return }
                        let moved = horizontal ? value.translation.width : value.translation.height
                        next.moveDivider(after: divider.index, by: Double(moved / length))
                        browser.store.send(.resizeSplit(split.tabs[0], fractions: next.fractions))
                    }
                    .onEnded { _ in start = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                animate(Motion.travel) {
                    _ = browser.store.send(.resizeSplit(split.tabs[0], fractions: Array(repeating: 1, count: split.tabs.count)))
                }
            })
            .accessibilityLabel("Split divider")
            .accessibilityHint("Drag to resize. Double-click to make the panes equal.")
    }
}

/// A grip on each pane's top edge: drag it to move the pane (or out of the split), click it to
/// focus the pane, right-click or use the chevron for the pane's menu.
private struct PaneGrip: View {
    let tab: TabID
    let split: TabSplit
    let focused: Bool
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "ellipsis")
                .frame(width: 26, height: 18)
                .contentShape(.rect)
                .onTapGesture { browser.store.send(.selectTab(tab)) }
                .modifier(PaneDrag(tab: tab, session: drag))
            if hovering {
                Menu {
                    PaneMenu(tab: tab, split: split)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(focused || hovering ? .primary : .secondary)
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .contextMenu { PaneMenu(tab: tab, split: split) }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Drag to move this pane")
    }
}

private struct PaneDrag: ViewModifier {
    let tab: TabID
    let session: TabDragSession
    @Environment(Browser.self) private var browser

    func body(content: Content) -> some View {
        if let tab = browser.store.state.tabs[tab] {
            content.tabDrag(tab, source: .pane, session: session)
        } else {
            content
        }
    }
}

private struct PaneMenu: View {
    let tab: TabID
    let split: TabSplit
    @Environment(Browser.self) private var browser

    var body: some View {
        let store = browser.store
        let index = split.tabs.firstIndex(of: tab) ?? 0
        let horizontal = split.axis == .horizontal
        if index > 0 {
            Button(horizontal ? "Move Left" : "Move Up") { animate(Motion.travel) { _ = store.send(.movePane(tab, to: index - 1)) } }
        }
        if index < split.tabs.count - 1 {
            Button(horizontal ? "Move Right" : "Move Down") { animate(Motion.travel) { _ = store.send(.movePane(tab, to: index + 1)) } }
        }
        Divider()
        SplitMenu(tab: tab)
        Button("Remove Pane from Split") { animate(Motion.travel) { _ = store.send(.leaveSplit(tab)) } }
        Divider()
        Button("Close Tab") { animate(Motion.travel) { _ = store.send(.closeTab(tab)) } }
    }
}

/// Takes a dragged tab over the page and shows the split it would make, updating as it moves.
private struct PageDropTarget: View {
    let layout: PaneLayout
    @Environment(Browser.self) private var browser
    @Environment(TabDragSession.self) private var drag
    @State private var target: SplitDropDelegate.Target?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(.rect)
            if let target, let moving = drag.active?.id {
                ArrangementPreview(panes: layout.arrangement(placing: moving, beside: target.tab, edge: target.edge,
                                                             state: browser.store.state),
                                   moving: moving)
                    .transition(Arrive(scale: 0.98))
            }
        }
        .onDrop(of: [.plainText, .utf8PlainText], delegate: SplitDropDelegate(
            layout: layout, browser: browser, session: drag, target: $target))
    }
}

/// The page as it would be after the drop: a pane of glass for each tab, the arriving one tinted.
/// The panes flow from place to place as the pointer moves from edge to edge.
private struct ArrangementPreview: View {
    let panes: [PaneLayout.Pane]
    let moving: TabID
    @Environment(Browser.self) private var browser
    @Namespace private var glass

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The page stays faintly in view behind the plan.
            Rectangle().fill(.ultraThinMaterial)
            GlassEffectContainer(spacing: PaneStyle.gap) {
                ZStack(alignment: .topLeading) {
                    ForEach(panes, id: \.tab) { pane in
                        card(pane.tab)
                            .frame(width: pane.frame.width, height: pane.frame.height)
                            .glassEffect(pane.tab == moving ? .regular.tint(.accentColor.opacity(0.35)) : .regular,
                                         in: .rect(cornerRadius: PaneStyle.radius, style: .continuous))
                            .glassEffectID(pane.tab, in: glass)
                            .offset(x: pane.frame.minX, y: pane.frame.minY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func card(_ id: TabID) -> some View {
        VStack(spacing: 10) {
            if let tab = browser.store.state.tabs[id] {
                Favicon(url: tab.faviconURL, page: tab.url, title: tab.displayTitle, size: 32)
                Text(tab.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(id == moving ? .primary : .secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SplitDropDelegate: DropDelegate {
    struct Target: Equatable { let tab: TabID; let edge: SplitEdge }

    let layout: PaneLayout
    let browser: Browser
    let session: TabDragSession
    @Binding var target: Target?

    func validateDrop(info: DropInfo) -> Bool { session.active != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let payload = session.active,
              let found = layout.dropTarget(at: info.location, dragging: payload, state: browser.store.state) else {
            show(nil)
            return DropProposal(operation: .forbidden)
        }
        show(Target(tab: found.tab, edge: found.edge))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { show(nil) }

    func performDrop(info: DropInfo) -> Bool {
        defer { target = nil; session.finish() }
        guard let payload = session.active, let target else { return false }
        return browser.drop(payload, on: .split(target.tab, target.edge))
    }

    private func show(_ next: Target?) {
        guard next != target else { return }
        animate(Motion.flow) { target = next }
    }
}

// MARK: - Prompts

/// Permission requests, page dialogs, agent approvals and the offer to save a password, as alerts.
private struct PromptAlerts: ViewModifier {
    @Environment(Browser.self) private var browser
    @State private var remember = true
    @State private var text = ""

    func body(content: Content) -> some View {
        let prompt = browser.prompts.prompt(for: browser.pages.visibleTabID)
        let offer = browser.passwords.offer.flatMap { $0.tabID == browser.pages.visibleTabID ? $0 : nil }
        content
            .alert(Self.title(prompt), isPresented: shown(prompt != nil), presenting: prompt) { prompt in
                switch prompt {
                case let .permission(_, request):
                    Button("Allow") { browser.prompts.answer(permission: request, allow: true, remember: remember) }
                    Button("Don't Allow", role: .cancel) { browser.prompts.answer(permission: request, allow: false, remember: remember) }
                case let .dialog(_, request):
                    if request.kind == .prompt {
                        TextField("", text: $text)
                    }
                    Button("OK") { browser.prompts.answer(dialog: request, ok: true, text: text) }
                    if request.kind != .alert {
                        Button("Cancel", role: .cancel) { browser.prompts.answer(dialog: request, ok: false) }
                    }
                case let .approval(approval):
                    Button("Allow") { browser.prompts.answer(approval: approval, allow: true) }
                    // Only an agent in an MCP session can be told apart from others claiming its name.
                    if approval.session != nil {
                        Button("Allow for This Session") { browser.prompts.answer(approval: approval, allow: true, trustClient: true) }
                    }
                    Button("Deny", role: .cancel) { browser.prompts.answer(approval: approval, allow: false) }
                }
            } message: { prompt in
                switch prompt {
                case .permission: Text("You can change this later in Settings.")
                case let .dialog(_, request): Text(request.message)
                case let .approval(approval): Text(approval.summary)
                }
            }
            .dialogSuppressionToggle("Remember for this website", isSuppressed: $remember)
            .alert(offer.map { $0.isUpdate ? "Update the password for \($0.credential.displayHost)?" : "Save the password for \($0.credential.displayHost)?" } ?? "",
                   isPresented: shown(prompt == nil && offer != nil), presenting: offer) { offer in
                Button(offer.isUpdate ? "Update Password" : "Save Password") { browser.passwords.acceptOffer() }
                if !offer.isUpdate {
                    Button("Never for This Website") { browser.passwords.dismissOffer(never: true) }
                }
                Button("Not Now", role: .cancel) { browser.passwords.dismissOffer() }
            } message: { offer in
                Text("Skylight keeps it in your login Keychain and fills it when you sign in again. Username: \(offer.credential.username.isEmpty ? "none" : offer.credential.username)")
            }
            .onChange(of: prompt?.id) { _, _ in
                remember = true
                if case let .dialog(_, request)? = prompt { text = request.defaultText }
            }
    }

    /// Alerts close themselves when answered; the answer is what removes the prompt.
    private func shown(_ value: Bool) -> Binding<Bool> { .constant(value) }

    static func title(_ prompt: Prompt?) -> String {
        switch prompt {
        case let .permission(_, request)? where request.isEmbedded:
            "\(host(request.origin)), inside \(host(request.topOrigin)), wants to \(describe(request.kinds))"
        case let .permission(_, request)?: "\(host(request.origin)) wants to \(describe(request.kinds))"
        case let .dialog(_, request)?: "\(host(request.origin)) says"
        case let .approval(approval)?: "\(approval.client) wants to act in Skylight"
        case nil: ""
        }
    }

    static func host(_ origin: String) -> String {
        URL(string: origin)?.host(percentEncoded: false) ?? (origin.isEmpty ? "This page" : origin)
    }

    static func describe(_ kinds: [PermissionRequest.Kind]) -> String {
        let phrases = kinds.map { kind -> String in
            switch kind {
            case .camera: "use your camera"
            case .microphone: "use your microphone"
            case .screen: "share your screen"
            case .geolocation: "know your location"
            case .notifications: "show notifications"
            case .clipboard: "see what you copy"
            case .midi: "use MIDI devices"
            case .fileSystem: "edit files"
            case .storageAccess: "use cookies on other sites"
            case .windowManagement: "manage windows"
            case .localFonts: "use your fonts"
            case .idleDetection: "know when you're idle"
            case .keyboardLock: "capture your keyboard"
            case .pointerLock: "lock your pointer"
            case .protocolHandler: "open links of a type"
            case .multipleDownloads: "download several files"
            case .other: "use a device feature"
            }
        }
        return ListFormatter.localizedString(byJoining: phrases)
    }

    static func symbol(_ kinds: [PermissionRequest.Kind]) -> String {
        switch kinds.first {
        case .camera: "video"
        case .microphone: "mic"
        case .screen: "rectangle.on.rectangle"
        case .geolocation: "location"
        case .notifications: "bell"
        case .clipboard: "doc.on.clipboard"
        default: "hand.raised"
        }
    }
}

// MARK: - Toasts

/// A short message at the bottom of the page, like a HUD.
struct ToastView: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        ZStack {
            if let toast = browser.toasts.current {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol)
                    Text(toast.message).lineLimit(1)
                    if let action = toast.action {
                        Button(action) { browser.toasts.runAction() }
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .glassEffect(.regular, in: .capsule)
                .id(toast.id)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .onTapGesture { withAnimation { browser.toasts.dismiss() } }
            }
        }
        .animation(.easeOut(duration: 0.2), value: browser.toasts.current)
        .padding(.bottom, 18)
    }
}
