import AppKit
import SkylightBrowser
import SkylightCore
import SkylightEngine
import SwiftUI

/// The page card: the engine's view, rounded and floating on the backdrop, with the progress
/// line, prompts and the empty state on top. A split gives each pane its own card, with the sky
/// showing between them, dividers to resize and a handle to rearrange.
struct ContentArea: View {
    @Environment(Browser.self) private var browser
    @Environment(TabDrag.self) private var drag
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var palette

    var body: some View {
        let state = browser.store.state
        let tab = state.selectedTab
        let split = tab.flatMap { state.activeSpace.split(containing: $0.id) }
        let preferences = browser.preferences

        GeometryReader { geo in
            let layout = PaneLayout(split: split, focused: tab?.id, size: geo.size, gap: preferences.splitGap)
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.tab) { pane in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.background)
                        .shadow(color: Theme.shadow(palette, scheme), radius: 18, y: 6)
                        .frame(width: pane.frame.width, height: pane.frame.height)
                        .offset(x: pane.frame.minX, y: pane.frame.minY)
                }
                .opacity(tab == nil ? 0 : 1)

                content(tab: tab, layout: layout)
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))

                ForEach(layout.panes, id: \.tab) { pane in
                    let focused = layout.isSplit && pane.tab == layout.focused && preferences.highlightFocusedPane
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(focused ? AnyShapeStyle(.tint.opacity(0.7)) : AnyShapeStyle(Surface.selected.edge(scheme)),
                                      lineWidth: focused ? 1.5 : 0.75)
                        .frame(width: pane.frame.width, height: pane.frame.height)
                        .offset(x: pane.frame.minX, y: pane.frame.minY)
                        .allowsHitTesting(false)
                }
                .opacity(tab == nil ? 0 : 1)

                if let split, layout.isSplit {
                    ForEach(layout.dividers, id: \.index) { divider in
                        SplitDivider(split: split, divider: divider, length: layout.length)
                    }
                    ForEach(layout.panes, id: \.tab) { pane in
                        PaneHandle(tab: pane.tab, split: split, focused: pane.tab == layout.focused)
                            .position(x: pane.frame.midX, y: pane.frame.minY)
                    }
                }

                if drag.isDragging, case let .split(target, edge)? = drag.target,
                   let frame = layout.panes.first(where: { $0.tab == target })?.frame ?? (layout.panes.count == 1 ? layout.panes[0].frame : nil) {
                    SplitDropPreview(frame: Self.preview(of: frame, edge: edge, gap: preferences.splitGap), radius: radius)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TabDrag.space)) } action: { origin in
                report(layout, origin: origin)
            }
            .onChange(of: layout.panes.map(\.frame)) {
                report(layout, origin: drag.contentFrame)
            }
        }
        .motion(Motion.swap, value: tab == nil)
        .onChange(of: preferences.splitGap) { browser.pages.relayout() }
        .onChange(of: preferences.cornerRadius) { browser.pages.relayout() }
    }

    /// The pages and what sits on them: the empty state, built-in pages, and the focused pane's
    /// progress line and prompts.
    private func content(tab: BrowserTab?, layout: PaneLayout) -> some View {
        let status = browser.selectedStatus
        let prompt = browser.prompts.prompt(for: browser.pages.visibleTabID)
        let offer = browser.passwords.offer
        let focus = layout.focusedFrame

        return ZStack(alignment: .topLeading) {
            PageHost(view: browser.pages.hostView, radius: radius)
            if tab == nil {
                StartView().transition(.opacity)
            } else if let tab, tab.url.isSkylightPage {
                SettingsPage(url: tab.url).transition(.opacity)
            }
            ZStack(alignment: .top) {
                ProgressLine(progress: status.progress, loading: status.isLoading)
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
                if let prompt {
                    PromptCard(prompt: prompt)
                        .id(prompt.id)
                        .padding(.top, 14)
                        .transition(Arrive(anchor: .top, scale: 0.96, rise: -8))
                } else if let offer, offer.tabID == browser.pages.visibleTabID {
                    PasswordOfferCard(offer: offer)
                        .id(offer.id)
                        .padding(.top, 14)
                        .transition(Arrive(anchor: .top, scale: 0.96, rise: -8))
                }
            }
            .frame(width: focus.width, height: focus.height, alignment: .top)
            .offset(x: focus.minX, y: focus.minY)
        }
        .motion(Motion.arrive, value: prompt?.id)
        .motion(Motion.arrive, value: offer?.id)
    }

    private func report(_ layout: PaneLayout, origin: CGRect) {
        drag.contentFrame = origin
        drag.panes = layout.panes.map { ($0.tab, $0.frame.offsetBy(dx: origin.minX, dy: origin.minY)) }
    }

    /// The half of `frame` a tab dropped on `edge` will take.
    static func preview(of frame: CGRect, edge: SplitEdge, gap: CGFloat) -> CGRect {
        let inset = frame.insetBy(dx: 8, dy: 8)
        switch edge {
        case .leading: return CGRect(x: inset.minX, y: inset.minY, width: inset.width / 2 - gap / 2, height: inset.height)
        case .trailing: return CGRect(x: inset.midX + gap / 2, y: inset.minY, width: inset.width / 2 - gap / 2, height: inset.height)
        case .top: return CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: inset.height / 2 - gap / 2)
        case .bottom: return CGRect(x: inset.minX, y: inset.midY + gap / 2, width: inset.width, height: inset.height / 2 - gap / 2)
        }
    }

    private var radius: CGFloat { browser.preferences.cornerRadius }
}

/// Where each pane of the card goes. Mirrors the page host's layout, so the cards, rings and
/// handles line up with the pages.
struct PaneLayout {
    struct Pane { let tab: TabID; let frame: CGRect }
    struct Divider { let index: Int; let frame: CGRect }

    let panes: [Pane]
    let focused: TabID?
    let axis: TabSplit.Axis
    /// The card's length along the split, less the gaps: what fractions are shares of.
    let length: CGFloat
    let gap: CGFloat

    init(split: TabSplit?, focused: TabID?, size: CGSize, gap: CGFloat) {
        self.focused = focused
        self.gap = gap
        axis = split?.axis ?? .horizontal
        if let split, split.tabs.count > 1 {
            panes = zip(split.tabs, split.frames(in: size, gap: gap)).map(Pane.init)
            let extent = split.axis == .horizontal ? size.width : size.height
            length = max(1, extent - gap * CGFloat(split.tabs.count - 1))
        } else {
            panes = focused.map { [Pane(tab: $0, frame: CGRect(origin: .zero, size: size))] } ?? []
            length = max(1, size.width)
        }
    }

    var isSplit: Bool { panes.count > 1 }

    var focusedFrame: CGRect {
        panes.first { $0.tab == focused }?.frame ?? panes.first?.frame ?? .zero
    }

    /// The gaps between panes, widened so they're easy to grab.
    var dividers: [Divider] {
        guard isSplit else { return [] }
        let reach = max(gap, 4) + 8
        return panes.dropLast().enumerated().map { i, pane in
            let f = pane.frame
            let frame = axis == .horizontal
                ? CGRect(x: f.maxX + gap / 2 - reach / 2, y: f.minY, width: reach, height: f.height)
                : CGRect(x: f.minX, y: f.maxY + gap / 2 - reach / 2, width: f.width, height: reach)
            return Divider(index: i, frame: frame)
        }
    }
}

/// Drag to resize the panes either side; double-click to make them equal.
private struct SplitDivider: View {
    let split: TabSplit
    let divider: PaneLayout.Divider
    let length: CGFloat
    @Environment(Browser.self) private var browser
    @State private var hovering = false
    @State private var start: TabSplit?

    var body: some View {
        let horizontal = split.axis == .horizontal
        let active = hovering || start != nil
        ZStack {
            Color.clear.contentShape(.rect)
            Capsule()
                .fill(.primary.opacity(active ? 0.35 : 0))
                .frame(width: horizontal ? 3 : 32, height: horizontal ? 32 : 3)
        }
        .frame(width: divider.frame.width, height: divider.frame.height)
        .offset(x: divider.frame.minX, y: divider.frame.minY)
        .pointerStyle(horizontal ? .columnResize : .rowResize)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(TabDrag.space))
                .onChanged { value in
                    if start == nil { start = browser.store.state.activeSpace.split(containing: split.tabs[0]) ?? split }
                    guard var next = start else { return }
                    let moved = horizontal ? value.translation.width : value.translation.height
                    next.moveDivider(after: divider.index, by: Double(moved / length))
                    browser.store.send(.resizeSplit(split.tabs[0], fractions: next.fractions))
                }
                .onEnded { _ in animate(Motion.feedback) { start = nil } }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            animate(Motion.travel) {
                _ = browser.store.send(.resizeSplit(split.tabs[0], fractions: Array(repeating: 1, count: split.tabs.count)))
            }
        })
        .help("Drag to resize · Double-click to make equal")
    }
}

/// A grip on each pane's top edge: drag it to move the pane (or out of the split), click it to
/// focus the pane; the chevron opens the pane's menu.
private struct PaneHandle: View {
    let tab: TabID
    let split: TabSplit
    let focused: Bool
    @Environment(Browser.self) private var browser
    @Environment(TabDrag.self) private var drag
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) }
            }
            .frame(width: 30, height: 16)
            .contentShape(.rect)
            .onTapGesture { _ = browser.store.send(.selectTab(tab)) }
            .tabDrag(tab, source: .pane, drag: drag, browser: browser)
            .pointerStyle(.grabIdle)

            if hovering {
                Menu {
                    PaneMenu(tab: tab, split: split)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }
        }
        .padding(.horizontal, 3)
        .foregroundStyle(focused || hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .surface(hovering ? .selected : .field, radius: 9, lifted: hovering)
        .contextMenu { PaneMenu(tab: tab, split: split) }
        .opacity(drag.item?.id == tab ? 0 : 1)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .help("Drag to move this pane")
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
        if store.state.selectedTabID != tab {
            Button("Focus This Pane") { _ = store.send(.selectTab(tab)) }
        }
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

/// Where a dragged tab will land.
private struct SplitDropPreview: View {
    let frame: CGRect
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: max(radius - 4, 6), style: .continuous)
            .fill(.tint.opacity(0.16))
            .strokeBorder(.tint.opacity(0.6), lineWidth: 1.5)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: max(radius - 4, 6), style: .continuous))
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(Motion.travel, value: frame)
    }
}

/// Hosts the coordinator's page container. SwiftUI never re-creates it, so pages keep running.
struct PageHost: NSViewRepresentable {
    let view: PageHostView
    var radius = Theme.cardRadius

    func makeNSView(context: Context) -> PageHostView {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: PageHostView, context: Context) {
        if view.layer?.cornerRadius != radius { view.layer?.cornerRadius = radius }
    }
}

private struct ProgressLine: View {
    let progress: Double
    let loading: Bool

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.tint)
                .frame(width: max(0, geo.size.width * (loading ? max(progress, 0.08) : 1)), height: 2.5)
                .opacity(loading ? 1 : 0)
                .motion(Motion.travel, value: progress)
                .motion(Motion.exit, value: loading)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

/// An empty tab: one field in the middle of the sky, where the command bar opens.
private struct StartView: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                    Text("Search or enter address").font(.system(size: 18))
                    Spacer()
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .frame(width: CommandBarLayout.width(in: geo.size.width), height: CommandBarLayout.fieldHeight)
                .surface(hovering ? .selected : .field, radius: 22)
                .contentShape(.rect)
                .onTapGesture { browser.presentCommandBar(.newTab) }
                .onHover { h in animate(Motion.feedback) { hovering = h } }

                Text("⌘T new tab   ·   ⌘L address   ·   ⌘S sidebar   ·   ⌘, settings")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, CommandBarLayout.top(in: geo.size.height, empty: true))
            .opacity(browser.commandBar.isPresented ? 0 : 1)
        }
    }
}

// MARK: - Prompts

private struct PromptCard: View {
    let prompt: Prompt
    @Environment(Browser.self) private var browser
    @State private var text = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch prompt {
            case let .permission(_, request):
                header(symbol: Self.symbol(request.kinds), title: "\(Self.host(request.origin)) wants to \(Self.describe(request.kinds))")
                Toggle("Remember for this site", isOn: $remember).toggleStyle(.checkbox).font(.system(size: 12))
                buttons(cancel: "Don't Allow", ok: "Allow",
                        onCancel: { browser.prompts.answer(permission: request, allow: false, remember: remember) },
                        onOK: { browser.prompts.answer(permission: request, allow: true, remember: remember) })

            case let .dialog(_, request):
                header(symbol: request.kind == .alert ? "exclamationmark.bubble" : "questionmark.bubble",
                       title: "\(Self.host(request.origin)) says")
                Text(request.message).font(.system(size: 13)).textSelection(.enabled).lineLimit(12)
                if request.kind == .prompt {
                    TextField("", text: $text).textFieldStyle(.roundedBorder)
                        .onAppear { text = request.defaultText }
                        .onSubmit { browser.prompts.answer(dialog: request, ok: true, text: text) }
                }
                buttons(cancel: request.kind == .alert ? nil : "Cancel", ok: "OK",
                        onCancel: { browser.prompts.answer(dialog: request, ok: false) },
                        onOK: { browser.prompts.answer(dialog: request, ok: true, text: text) })

            case let .approval(approval):
                header(symbol: "sparkles", title: "\(approval.client) wants to act in Skylight")
                Text(approval.summary).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(4)
                HStack {
                    Button("Allow for This Session") { browser.prompts.answer(approval: approval, allow: true, trustClient: true) }
                        .buttonStyle(.glass)
                    Spacer()
                    Button("Deny") { browser.prompts.answer(approval: approval, allow: false) }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button("Allow") { browser.prompts.answer(approval: approval, allow: true) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
    }

    private func header(symbol: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.tint)
            Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
        }
    }

    private func buttons(cancel: String?, ok: String, onCancel: @escaping () -> Void, onOK: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            if let cancel {
                Button(cancel, action: onCancel).buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            Button(ok, action: onOK).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
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

struct ToastView: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        ZStack {
            if let toast = browser.toasts.current {
                HStack(spacing: 9) {
                    Image(systemName: toast.symbol).font(.system(size: 13, weight: .medium))
                    Text(toast.message).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let action = toast.action {
                        Button(action) { browser.toasts.runAction() }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                .surface(.selected, radius: 19, lifted: true)
                .id(toast.id)
                .transition(Arrive(anchor: .bottom, scale: 0.94, rise: 10))
                .onTapGesture { animate(Motion.exit) { browser.toasts.dismiss() } }
            }
        }
        .motion(Motion.arrive, value: browser.toasts.current)
        .padding(.bottom, 22)
    }
}
