import AppKit
import Observation
import SkylightCore
import SkylightEngine

/// What a page reports that isn't browser state: messages, prompts and downloads.
@MainActor
public protocol PageEventSink: AnyObject {
    func tab(_ id: TabID, didReceive message: JSONValue) async throws -> JSONValue
    func tab(_ id: TabID, requestsPermission request: PermissionRequest)
    func tab(_ id: TabID, requestsDialog request: DialogRequest)
    func tab(_ id: TabID, didFinishDownload fileURL: URL)
}

/// Runs the engine side of the browser: turns reducer effects into page calls, creates pages
/// lazily, puts idle ones to sleep, and reports what pages do back to the store.
///
/// Tabs and pages are separate on purpose. A tab is a saved place; a page is the live engine
/// object, which exists only while the tab is awake.
@MainActor
@Observable
public final class PageCoordinator: BrowserEffectHandler {
    /// Holds every awake page's view. The visible page is the only one not hidden, so page views
    /// are never re-parented (which Chromium dislikes).
    @ObservationIgnored public let hostView = PageHostView()
    /// The focused tab: the one the address bar and shortcuts act on.
    public private(set) var visibleTabID: TabID?
    /// Every tab on screen: the focused tab's split, or just the focused tab.
    public private(set) var visibleTabIDs: [TabID] = []
    /// Space between split panes and their corner radius.
    @ObservationIgnored public var paneStyle: @MainActor () -> (gap: CGFloat, radius: CGFloat) = { (PaneStyle.gap, PaneStyle.radius) }

    @ObservationIgnored public var policy = HibernationPolicy()
    /// Today tabs idle this long are archived.
    @ObservationIgnored public var archiveAfter: @MainActor () -> TimeInterval = { 12 * 60 * 60 }
    @ObservationIgnored public weak var sink: PageEventSink?
    /// A tab's page went away. `tabClosed` is true when the tab itself is gone.
    @ObservationIgnored public var onPageGone: (@MainActor (TabID, _ tabClosed: Bool) -> Void)?
    /// Pages woke, slept, appeared or got their address: extensions want to know.
    @ObservationIgnored public var onPagesChange: (@MainActor () -> Void)?

    @ObservationIgnored private let engine: WebEngine
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var pages: [TabID: WebPage] = [:]
    @ObservationIgnored private var tabForPage: [ObjectIdentifier: TabID] = [:]
    @ObservationIgnored private var profiles: [ProfileID: WebProfile] = [:]
    @ObservationIgnored private var lastSeen: [TabID: Date] = [:]
    @ObservationIgnored private var closing: Set<ObjectIdentifier> = []
    @ObservationIgnored private var sweepTimer: Timer?
    @ObservationIgnored private var clickMonitor: Any?

    public init(engine: WebEngine, paths: AppPaths, store: BrowserStore) {
        self.engine = engine
        self.paths = paths
        self.store = store
    }

    public func start() {
        perform([.showTab(store?.state.selectedTabID)], store: store!)
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        // A click in another pane of a split moves focus there (the click still reaches the page).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.focusPane(at: event) }
            return event
        }
    }

    private func focusPane(at event: NSEvent) {
        guard visibleTabIDs.count > 1, event.window === hostView.window, let store else { return }
        let point = hostView.convert(event.locationInWindow, from: nil)
        guard let hit = visibleTabIDs.first(where: { pages[$0].map { !$0.view.isHidden && $0.view.frame.contains(point) } ?? false }),
              hit != visibleTabID else { return }
        store.send(.selectTab(hit))
    }

    // MARK: - Effects

    public func perform(_ effects: [BrowserEffect], store: BrowserStore) {
        for effect in effects {
            switch effect {
            case let .showTab(id): show(id)
            case let .load(id, url):
                if let page = pages[id] { page.load(url) } else if visibleTabIDs.contains(id) { wake(id) }
            case let .goBack(id): pages[id]?.goBack()
            case let .goForward(id): pages[id]?.goForward()
            case let .reload(id): if let page = pages[id] { page.reload() } else { wake(id) }
            case let .stop(id): pages[id]?.stop()
            case let .discardPage(id): sleep(id)
            case let .releaseProfile(id): profiles[id] = nil
            }
        }
    }

    private func show(_ id: TabID?) {
        let state = store?.state
        let split = id.flatMap { state?.activeSpace.split(containing: $0) }
        var panes = split?.tabs ?? id.map { [$0] } ?? []
        panes = panes.filter { state?.tabs[$0] != nil }
        guard let id, panes.contains(id) else { return hideAll() }

        if Set(panes) != Set(visibleTabIDs), let layer = hostView.layer {
            // Tabs swap as a quick crossfade, never a hard cut.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.75, 0.1, 1)
            layer.add(fade, forKey: "swap")
        }
        for old in visibleTabIDs where !panes.contains(old) { conceal(old) }
        let focusChanged = visibleTabID != id
        visibleTabIDs = panes
        visibleTabID = id
        var views: [NSView] = []
        for pane in panes {
            guard let page = pages[pane] ?? wake(pane) else { continue }
            page.view.isHidden = false
            page.setVisible(true)
            lastSeen[pane] = .now
            views.append(page.view)
        }
        let style = paneStyle()
        hostView.arrange(views, split: views.count == panes.count ? split : nil, gap: style.gap, radius: style.radius)
        if focusChanged || views.count == 1, let page = pages[id] { hostView.window?.makeFirstResponder(page.view) }
        onPagesChange?()
    }

    private func hideAll() {
        for old in visibleTabIDs { conceal(old) }
        visibleTabIDs = []
        visibleTabID = nil
        hostView.arrange([], split: nil, gap: 0, radius: 0)
        onPagesChange?()
    }

    private func conceal(_ id: TabID) {
        guard let page = pages[id] else { return }
        page.view.isHidden = true
        page.setVisible(false)
        lastSeen[id] = .now
    }

    /// Lays the visible panes out again (after the gap or radius preference changes).
    public func relayout() { show(visibleTabID) }

    // MARK: - Page lifetimes

    /// The tab's page, created (in the background if the tab isn't visible) when it's asleep.
    @discardableResult
    public func wake(_ id: TabID) -> WebPage? {
        if let page = pages[id] { return page }
        guard let store, let tab = store.state.tabs[id], !tab.url.isSkylightPage else { return nil }
        let page = engine.makePage(url: tab.url, profile: profile(for: store.state.profileID(forTab: id)), delegate: self)
        pages[id] = page
        tabForPage[ObjectIdentifier(page)] = id
        lastSeen[id] = .now
        page.view.isHidden = !visibleTabIDs.contains(id)
        page.setVisible(visibleTabIDs.contains(id))
        hostView.addPage(page.view)
        store.updateStatus(id) { $0.isAwake = true }
        return page
    }

    public func page(for id: TabID) -> WebPage? { pages[id] }

    public var awakePages: [WebPage] { Array(pages.values) }

    /// Awake pages with their tabs.
    public var awake: [(tab: TabID, page: WebPage)] { pages.map { ($0.key, $0.value) } }

    /// Gives keyboard focus back to the visible page.
    public func focusVisiblePage() {
        guard let id = visibleTabID, let page = pages[id] else { return }
        hostView.window?.makeFirstResponder(page.view)
    }

    /// Closes the tab's page but keeps the tab. It reloads when shown again.
    public func sleep(_ id: TabID) {
        defer { onPageGone?(id, store?.state.tabs[id] == nil) }
        guard let page = pages.removeValue(forKey: id) else { return }
        closing.insert(ObjectIdentifier(page))
        page.view.removeFromSuperview()
        page.close()
        lastSeen[id] = nil
        store?.updateStatus(id) { $0 = PageStatus() }
        onPagesChange?()
    }

    public func profile(for id: ProfileID) -> WebProfile {
        if let profile = profiles[id] { return profile }
        let profile = engine.makeProfile(directory: paths.profileDirectory(for: id))
        profiles[id] = profile
        return profile
    }

    /// Sleeps idle pages and archives idle Today tabs.
    func sweep(now: Date = .now) {
        guard let store else { return }
        var protected = store.state.selectedTabIDs
        protected.formUnion(visibleTabIDs)
        for id in policy.pagesToSleep(awake: lastSeen, protected: protected, now: now) { sleep(id) }
        store.send(.archiveTabs(idleSince: now.addingTimeInterval(-archiveAfter())))
    }

    /// Waits until the tab's page has finished loading (or `timeout` passes).
    public func waitUntilLoaded(_ id: TabID, timeout: Duration = .seconds(10)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        try? await Task.sleep(for: .milliseconds(150))
        while clock.now < deadline, store?.status(of: id).isLoading == true {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func closeAll(completion: @escaping @MainActor () -> Void) {
        sweepTimer?.invalidate()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        for page in pages.values { closing.insert(ObjectIdentifier(page)) }
        engine.closeAll(completion: completion)
    }
}

// MARK: - WebPageDelegate

extension PageCoordinator: WebPageDelegate {
    private func tab(of page: WebPage) -> TabID? { tabForPage[ObjectIdentifier(page)] }

    public func page(_ page: WebPage, didChange event: PageEvent) {
        guard let id = tab(of: page), let store else { return }
        if event.url != nil || event.title != nil || event.faviconURL != nil {
            store.send(.pageDidUpdate(id, PageMetadata(url: event.url, title: event.title, faviconURL: event.faviconURL)))
        }
        if event.url != nil || event.extensionTabID != nil { onPagesChange?() }
        store.updateStatus(id) { status in
            if let v = event.isLoading { status.isLoading = v }
            if let v = event.progress { status.progress = v }
            if let v = event.canGoBack { status.canGoBack = v }
            if let v = event.canGoForward { status.canGoForward = v }
        }
    }

    public func page(_ page: WebPage, wantsNewTab url: URL, inBackground: Bool) {
        guard let id = tab(of: page), let store else { return }
        store.send(.openTab(url, placement: .afterSelected, select: !inBackground, space: store.state.space(containing: id)?.id))
    }

    public func page(_ page: WebPage, didReceive message: JSONValue) async throws -> JSONValue {
        guard let id = tab(of: page), let sink else { throw WebEngineError.pageClosed }
        return try await sink.tab(id, didReceive: message)
    }

    public func page(_ page: WebPage, requestsPermission request: PermissionRequest) {
        guard let id = tab(of: page), let sink else { return request.respond(false) }
        sink.tab(id, requestsPermission: request)
    }

    public func page(_ page: WebPage, requestsDialog request: DialogRequest) {
        guard let id = tab(of: page), let sink else { return request.respond(false, "") }
        sink.tab(id, requestsDialog: request)
    }

    public func page(_ page: WebPage, didFinishDownload fileURL: URL) {
        guard let id = tab(of: page) else { return }
        sink?.tab(id, didFinishDownload: fileURL)
    }

    public func pageDidClose(_ page: WebPage) {
        let key = ObjectIdentifier(page)
        let id = tabForPage.removeValue(forKey: key)
        if closing.remove(key) != nil { return }
        // The page closed itself (window.close()): close its tab too.
        guard let id else { return }
        pages[id] = nil
        page.view.removeFromSuperview()
        store?.send(.closeTab(id))
        onPageGone?(id, true)
    }
}

/// How a split's panes sit in the window: rounded cards, apart from each other and from the
/// window's edges, on the window's backdrop.
public enum PaneStyle {
    public static let gap: CGFloat = 6
    public static let radius: CGFloat = 10
    public static let inset: CGFloat = 6

    /// Each pane's frame in a content area of `size`.
    public static func frames(of split: TabSplit, in size: CGSize, gap: CGFloat = gap) -> [CGRect] {
        let inner = CGSize(width: max(0, size.width - inset * 2), height: max(0, size.height - inset * 2))
        return split.frames(in: inner, gap: gap).map { $0.offsetBy(dx: inset, dy: inset) }
    }
}

/// Hosts page views. Alone, a page fills the bounds; in a split, each visible page gets its pane.
public final class PageHostView: NSView {
    public override var isFlipped: Bool { true }

    private var panes: [NSView] = []
    private var split: TabSplit?
    private var gap: CGFloat = 0
    private var radius: CGFloat = 0

    func addPage(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = []
        view.wantsLayer = true
        addSubview(view)
    }

    func arrange(_ views: [NSView], split: TabSplit?, gap: CGFloat, radius: CGFloat) {
        panes = views
        self.split = views.count > 1 ? split : nil
        self.gap = gap
        self.radius = radius
        layoutPanes()
    }

    /// Each visible page's frame, in this view's coordinates.
    public var paneFrames: [CGRect] { panes.map(\.frame) }

    public override func resizeSubviews(withOldSize oldSize: NSSize) { layoutPanes() }

    private func layoutPanes() {
        let frames = split.map { PaneStyle.frames(of: $0, in: bounds.size, gap: gap) }
        for view in subviews {
            if let frames, let i = panes.firstIndex(where: { $0 === view }) {
                view.frame = frames[i]
                view.layer?.cornerRadius = radius
                view.layer?.cornerCurve = .continuous
                view.layer?.masksToBounds = true
            } else {
                view.frame = bounds
                view.layer?.cornerRadius = 0
            }
        }
    }
}
