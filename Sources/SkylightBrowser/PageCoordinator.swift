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
    /// The tab whose page is in fullscreen (a video's fullscreen button). It fills the page area,
    /// even in a split, and the window hides everything else.
    public private(set) var fullscreenTabID: TabID?
    /// Space between split panes and their corner radius.
    @ObservationIgnored public var paneStyle: @MainActor () -> (gap: CGFloat, radius: CGFloat) = { (PaneStyle.gap, PaneStyle.radius) }

    @ObservationIgnored public var policy = HibernationPolicy(memoryBytes: ProcessInfo.processInfo.physicalMemory)
    /// Today tabs idle this long are archived.
    @ObservationIgnored public var archiveAfter: @MainActor () -> TimeInterval = { 12 * 60 * 60 }
    @ObservationIgnored public weak var sink: PageEventSink?
    /// A tab's page went away. `tabClosed` is true when the tab itself is gone.
    @ObservationIgnored public var onPageGone: (@MainActor (TabID, _ tabClosed: Bool) -> Void)?
    /// Pages woke, slept, appeared or got their address: extensions want to know.
    @ObservationIgnored public var onPagesChange: (@MainActor () -> Void)?
    /// Tabs that must not sleep, on top of those on screen: anything playing, say.
    @ObservationIgnored public var staysAwake: (@MainActor () -> Set<TabID>)?
    /// A tab went somewhere, or learned its page's title.
    @ObservationIgnored public var onVisit: (@MainActor (TabID, URL?, String?) -> Void)?
    /// A page went into fullscreen or came out of it: the window follows.
    @ObservationIgnored public var onFullscreenChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private let engine: WebEngine
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var pages: [TabID: WebPage] = [:]
    /// The profile each page was made in, which its tab's Space may have left since.
    @ObservationIgnored private var pageProfiles: [TabID: ProfileID] = [:]
    @ObservationIgnored private var tabForPage: [ObjectIdentifier: TabID] = [:]
    @ObservationIgnored private var profiles: [ProfileID: WebProfile] = [:]
    @ObservationIgnored private var lastSeen: [TabID: Date] = [:]
    @ObservationIgnored private var closing: Set<ObjectIdentifier> = []
    @ObservationIgnored private var sweepTimer: Timer?
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?
    @ObservationIgnored private var covered: CGFloat = 0
    @ObservationIgnored private var settling: Task<Void, Never>?

    /// How many of the last-used tabs get their pages back after launch.
    private static let warmedOnLaunch = 3

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
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.shedPages() }
        }
        pressure.resume()
        memoryPressure = pressure
        Task { await warmRecentTabs() }
    }

    /// Going back to a tab should find it there, not load it, so the tabs in use last come back
    /// behind the scenes: one at a time, after the page on screen, so they never hold it up.
    private func warmRecentTabs() async {
        guard let store, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        if let visibleTabID { await waitUntilLoaded(visibleTabID) }
        let tabs = store.state.spaces.flatMap(\.allTabIDs).compactMap { store.state.tabs[$0] }
        let recent = tabs.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(Self.warmedOnLaunch)
        for tab in recent where pages[tab.id] == nil {
            guard wake(tab.id) != nil else { continue }
            await waitUntilLoaded(tab.id, timeout: .seconds(5))
        }
    }

    private func shedPages() {
        for id in policy.pagesToShed(awake: lastSeen, protected: protectedTabs()) { sleep(id) }
    }

    private func protectedTabs() -> Set<TabID> {
        var protected = store?.state.selectedTabIDs ?? []
        protected.formUnion(visibleTabIDs)
        protected.formUnion(staysAwake?() ?? [])
        return protected
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
            case let .hardReload(id): if let page = pages[id] { page.hardReload() } else { wake(id) }
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
        // Fullscreen ends when its page leaves the screen.
        if let full = fullscreenTabID, !panes.contains(full) {
            pages[full]?.exitFullscreen()
            setFullscreen(nil, relayout: false)
        }
        for old in visibleTabIDs where !panes.contains(old) { conceal(old) }
        let focusChanged = visibleTabID != id
        visibleTabIDs = panes
        visibleTabID = id
        var views: [NSView] = []
        for pane in panes {
            guard let page = wake(pane) else { continue }
            page.setCovered(cover(of: pane))
            page.view.isHidden = false
            page.setVisible(true)
            lastSeen[pane] = .now
            views.append(page.view)
        }
        let style = paneStyle()
        if let full = fullscreenTabID, let page = pages[full] {
            for view in views where view !== page.view { view.isHidden = true }
            hostView.arrange([page.view], split: nil, gap: 0, radius: 0)
        } else {
            hostView.arrange(views, split: views.count == panes.count ? split : nil, gap: style.gap, radius: style.radius)
        }
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

    /// How much of the window's left lies over a page alone. Pages on screen follow at once; the
    /// rest wait until it settles, so dragging the sidebar's edge doesn't lay out every open tab.
    public func setCovered(_ width: CGFloat) {
        guard width != covered else { return }
        covered = width
        hostView.coveredWidth = width
        for id in visibleTabIDs { pages[id]?.setCovered(cover(of: id)) }
        settling?.cancel()
        settling = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            for (id, page) in self.pages { page.setCovered(self.cover(of: id)) }
        }
    }

    /// A split's panes sit beside the sidebar, so nothing covers them.
    private func cover(of id: TabID) -> CGFloat {
        visibleTabIDs.count > 1 && visibleTabIDs.contains(id) ? 0 : covered
    }

    /// The colour of the page on screen.
    public var visiblePageColor: NSColor { visibleTabID.flatMap { pages[$0]?.backgroundColor } ?? .clear }

    /// Brings the fullscreen page back into the window.
    public func exitFullscreen() {
        guard let id = fullscreenTabID else { return }
        pages[id]?.exitFullscreen()
        setFullscreen(nil)
    }

    private func setFullscreen(_ id: TabID?, relayout again: Bool = true) {
        guard fullscreenTabID != id else { return }
        fullscreenTabID = id
        if again { relayout() }
        onFullscreenChange?(id != nil)
    }

    // MARK: - Page lifetimes

    /// The tab's page, created (in the background if the tab isn't visible) when it's asleep.
    @discardableResult
    public func wake(_ id: TabID) -> WebPage? {
        if let page = pages[id] {
            // A page stays signed in to the profile it was made in, so it can't carry on in a
            // Space on another one.
            guard let store, store.state.profileID(forTab: id) != pageProfiles[id] else { return page }
            sleep(id)
        }
        guard let store, let tab = store.state.tabs[id], !tab.url.isSkylightPage else { return nil }
        let profileID = store.state.profileID(forTab: id)
        let page = engine.makePage(url: tab.url, profile: profile(for: profileID), delegate: self)
        pages[id] = page
        pageProfiles[id] = profileID
        tabForPage[ObjectIdentifier(page)] = id
        lastSeen[id] = .now
        page.setCovered(cover(of: id))
        page.view.isHidden = !visibleTabIDs.contains(id)
        page.setVisible(visibleTabIDs.contains(id))
        hostView.addPage(page.view)
        store.updateStatus(id) {
            $0.isAwake = true
            $0.isLoading = page.isLoading
        }
        return page
    }

    public func page(for id: TabID) -> WebPage? { pages[id] }

    public var awakePages: [WebPage] { Array(pages.values) }

    /// Awake pages with their tabs.
    public var awake: [(tab: TabID, page: WebPage, profile: ProfileID)] {
        pages.compactMap { id, page in pageProfiles[id].map { (id, page, $0) } }
    }

    /// Gives keyboard focus back to the visible page.
    public func focusVisiblePage() {
        guard let id = visibleTabID, let page = pages[id], let window = hostView.window else { return }
        window.makeFirstResponder(page.view)
        // In full screen the address field was in the toolbar's own window.
        window.makeKey()
    }

    /// Closes the tab's page but keeps the tab. It reloads when shown again.
    public func sleep(_ id: TabID) {
        defer { onPageGone?(id, store?.state.tabs[id] == nil) }
        if fullscreenTabID == id { setFullscreen(nil, relayout: false) }
        guard let page = pages.removeValue(forKey: id) else { return }
        pageProfiles[id] = nil
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

    /// Deletes what the profile kept. Its Spaces are already gone.
    func deleteProfile(_ id: ProfileID) async {
        guard let profile = profiles.removeValue(forKey: id) else { return }
        await engine.deleteProfile(profile)
    }

    /// The sites this profile is signed in to.
    func signedInSites(in id: ProfileID) async -> [SignInSite] {
        let names = await profile(for: id).cookieNames(domains: SignInSite.allCases.flatMap(\.domains))
        return SignInSite.allCases.filter { !$0.signedInCookies.isDisjoint(with: names) }
    }

    /// Copies what these extensions keep. `target` must not have been opened yet.
    func copyExtensionData(_ ids: [String], from source: ProfileID, to target: ProfileID) async throws {
        try await engine.copyExtensionData(ids, from: profile(for: source), to: paths.profileDirectory(for: target))
    }

    func copyCookies(_ domains: [String], from source: ProfileID, to target: ProfileID) async -> Int {
        await profile(for: source).copyCookies(domains: domains, to: profile(for: target))
    }

    func addCookies(_ cookies: [WebCookie], to target: ProfileID) async -> Int {
        await profile(for: target).addCookies(cookies)
    }

    /// Sleeps idle pages and archives idle Today tabs.
    func sweep(now: Date = .now) {
        guard let store else { return }
        for id in policy.pagesToSleep(awake: lastSeen, protected: protectedTabs(), now: now) { sleep(id) }
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

    public func closeAll() {
        sweepTimer?.invalidate()
        memoryPressure?.cancel()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        for page in pages.values { closing.insert(ObjectIdentifier(page)) }
        engine.closeAll()
    }
}

// MARK: - WebPageDelegate

extension PageCoordinator: WebPageDelegate {
    func tab(of page: WebPage) -> TabID? { tabForPage[ObjectIdentifier(page)] }

    public func page(_ page: WebPage, didChange event: PageEvent) {
        guard let id = tab(of: page), let store else { return }
        if event.url != nil || event.title != nil || event.faviconURL != nil {
            store.send(.pageDidUpdate(id, PageMetadata(url: event.url, title: event.title, faviconURL: event.faviconURL)))
        }
        if event.url != nil { onPagesChange?() }
        if event.url != nil || event.title != nil { onVisit?(id, event.url, event.title) }
        if let full = event.isFullscreen {
            if full, visibleTabIDs.contains(id) { setFullscreen(id) } else if !full, fullscreenTabID == id { setFullscreen(nil) }
        }
        if let progress = event.progress { store.setProgress(id, progress) }
        store.updateStatus(id) { status in
            if let v = event.isLoading { status.isLoading = v }
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
        pageProfiles[id] = nil
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

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not from a coder") }

    private var panes: [NSView] = []
    private var split: TabSplit?
    private var gap: CGFloat = 0
    private var radius: CGFloat = 0
    private var arrival: CheckedContinuation<Void, Never>?
    /// The sidebar width this view is waiting to make room for, before an opening slide runs.
    private var opening: CGFloat?
    /// Counts slides, so a late timeout can't end a newer one's wait.
    private var slideNumber = 0
    /// While the sidebar slides: where in the window the page starts, from where to where, and when.
    private var slideEdge: CGFloat?
    private var edgeFrom: CGFloat = 0
    private var edgeTo: CGFloat = 0
    private var edgeStart: CFTimeInterval = 0
    private var edgeSeconds: Double = 0
    private var edgeTiming = CAMediaTimingFunction(name: .linear)
    private var edgeLink: CADisplayLink?
    private let pageEdge = CALayer()
    private let barBand = CALayer()
    private var glassEdge: NSGlassEffectView?
    private let pin = RightPin()
    /// How much of a page's left side something covers.
    var coveredWidth: CGFloat = 0 { didSet { layoutPanes() } }
    private var clearsSlideOnResize = false

    func addPage(_ view: NSView) {
        view.frame = lonePageFrame
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

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutPanes()
    }

    /// A page alone reaches out of sight past this view's left edge, up to the window's or by what
    /// covers it, whichever is more. It lays out beside what covers it, so the same frame serves as
    /// the edge moves over it. While the sidebar slides, the page starts at the sliding edge instead
    /// and keeps its right edge where it is.
    private var lonePageFrame: CGRect {
        let reach = self.reach
        if let slideEdge {
            let x = slideEdge - reach - coveredWidth
            return CGRect(x: x, y: 0, width: bounds.width - x, height: bounds.height)
        }
        let lead = reach > 0 ? reach : coveredWidth
        return CGRect(x: -lead, y: 0, width: bounds.width + lead, height: bounds.height)
    }

    /// How far this view's left edge is from the window's.
    private var reach: CGFloat { max(0, (window?.contentView?.bounds.width ?? bounds.width) - bounds.width) }

    /// How far the sliding edge is from where it's going.
    public var slideOffset: CGFloat { slideEdge == nil ? 0 : edge(at: CACurrentMediaTime()) - edgeTo }

    /// Where the sliding edge is at `time`, in the window.
    private func edge(at time: CFTimeInterval) -> CGFloat {
        guard edgeSeconds > 0 else { return edgeTo }
        let done = min(1, max(0, (time - edgeStart) / edgeSeconds))
        return edgeFrom + (edgeTo - edgeFrom) * CGFloat(Self.eased(edgeTiming, done))
    }

    /// The timing curve's value at `x`.
    private static func eased(_ timing: CAMediaTimingFunction, _ x: Double) -> Double {
        var one: [Float] = [0, 0], two: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &one)
        timing.getControlPoint(at: 2, values: &two)
        func curve(_ t: Double, _ a: Float, _ b: Float) -> Double {
            let u = 1 - t
            return 3 * u * u * t * Double(a) + 3 * u * t * t * Double(b) + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if curve(mid, one[0], two[0]) < x { low = mid } else { high = mid }
        }
        return curve((low + high) / 2, one[1], two[1])
    }

    /// How far this view's top is from the window's.
    private var barHeight: CGFloat {
        guard let window else { return 0 }
        let inWindow = convert(bounds, to: nil)
        return max(0, window.frame.height - inWindow.maxY)
    }

    /// Gets the page ready to slide with the sidebar's edge, which is `width` wide. A page laid
    /// out for a new width lands a little after it's asked for, so until then its right side is
    /// held where it was, and its left side shows `color`.
    public func beginSlide(closing: Bool, width: CGFloat, color: NSColor) {
        clearsSlideOnResize = false
        // A slide cut short by this one stops waiting: its task was cancelled and ends there.
        slideNumber += 1
        arrive()
        guard split == nil else { return }
        let from = slideEdge == nil ? reach : edge(at: CACurrentMediaTime())
        edgeLink?.invalidate()
        edgeLink = nil
        edgeSeconds = 0
        edgeFrom = from
        edgeTo = closing ? 0 : width
        slideEdge = from
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipsToBounds = false
        // Only what's right of the sliding edge shows; the page reaches under the sidebar.
        pageEdge.backgroundColor = NSColor.black.cgColor
        pageEdge.removeAllAnimations()
        layer?.mask = pageEdge
        // The toolbar's dark band over the page goes with its edge, or its colour would change all at once.
        effectiveAppearance.performAsCurrentDrawingAppearance { barBand.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        barBand.removeAllAnimations()
        if barBand.superlayer == nil { layer?.addSublayer(barBand) }
        placeEdgeLayers(at: from, width: width)
        if let page = panes.first { pin.start(page, color: color.cgColor) }
        if closing || Self.same(reach, width) {
            layoutPanes()
        } else {
            opening = width
        }
        CATransaction.commit()
    }

    private func placeEdgeLayers(at edge: CGFloat, width: CGFloat) {
        let bar = barHeight, x = edge - reach
        pageEdge.frame = CGRect(x: x, y: isFlipped ? -bar : 0, width: 3 * (window?.contentView?.bounds.width ?? bounds.width), height: bounds.height + bar)
        barBand.frame = CGRect(x: x, y: isFlipped ? -bar : bounds.height, width: width, height: bar)
        glassEdge?.frame = CGRect(x: x, y: 0, width: Self.glassEdgeWidth, height: bounds.height)
    }

    /// Returns once this view is where the slide needs it.
    public func slideReady() async {
        guard opening != nil else { return }
        let number = slideNumber
        await withCheckedContinuation { continuation in
            arrival = continuation
            // If the room never comes (the window changed under it, say), slide anyway.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.slideNumber == number else { return }
                self.arrive()
            }
        }
    }

    private func arrive() {
        opening = nil
        let waiting = arrival
        arrival = nil
        waiting?.resume()
    }

    /// The view's frame lands on the pixel grid, and a dragged width needn't.
    private static func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }

    /// Slides the edge to where it rests. Core Animation moves the edge itself, so nothing the app
    /// or the page does can make it step; the page's frame follows every frame, a little ahead.
    public func runSlide(seconds: Double, timing: CAMediaTimingFunction) {
        guard slideEdge != nil else { return }
        edgeStart = CACurrentMediaTime()
        edgeSeconds = seconds
        edgeTiming = timing
        let width = barBand.frame.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        showGlassEdge(seconds: seconds)
        placeEdgeLayers(at: edgeTo, width: width)
        for moving in [pageEdge, barBand, glassEdge?.layer].compactMap({ $0 }) {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = edgeFrom - edgeTo
            slide.toValue = 0
            slide.duration = seconds
            slide.timingFunction = timing
            slide.beginTime = moving.convertTime(edgeStart, from: nil)
            slide.fillMode = .backwards
            moving.add(slide, forKey: "slide")
        }
        CATransaction.commit()
        let link = displayLink(target: self, selector: #selector(followEdge))
        link.add(to: .main, forMode: .common)
        edgeLink = link
    }

    /// Keeps the page's left side ahead of the edge, under the sidebar. A layout lands a few frames
    /// after it's asked for, so a page getting wider asks for where the edge will be by then; one
    /// getting narrower is covered while it catches up.
    @objc private func followEdge() {
        let now = CACurrentMediaTime()
        let ahead = edgeTo < edgeFrom ? 0.05 : 0
        slideEdge = edge(at: now + ahead)
        if now - edgeStart >= edgeSeconds {
            slideEdge = edgeTo
            edgeLink?.invalidate()
            edgeLink = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panes.first?.frame = lonePageFrame
        pin.update()
        CATransaction.commit()
    }

    /// A strip of Liquid Glass rides the page's leading edge while it moves.
    private func showGlassEdge(seconds: Double) {
        let glass = glassEdge ?? NSGlassEffectView()
        if glassEdge == nil {
            glass.style = .clear
            glass.cornerRadius = 10
            glass.wantsLayer = true
            glass.alphaValue = 0
            glassEdge = glass
            addSubview(glass)
        }
        glass.layer?.zPosition = 2
        let shine = CAKeyframeAnimation(keyPath: "opacity")
        shine.values = [0, 1, 1, 0]
        shine.keyTimes = [0, 0.08, 0.6, 1]
        shine.duration = seconds
        glass.layer?.add(shine, forKey: "shine")
    }

    private static let glassEdgeWidth: CGFloat = 20

    /// Ends the slide. With `afterResize` it ends when this view next changes size, in the same
    /// frame, so a page that has just reached the window's edge doesn't blink.
    public func finishSlide(afterResize: Bool) {
        if afterResize { clearsSlideOnResize = true } else { clearSlide() }
    }

    private func clearSlide() {
        clearsSlideOnResize = false
        edgeLink?.invalidate()
        edgeLink = nil
        slideEdge = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageEdge.removeAllAnimations()
        barBand.removeAllAnimations()
        glassEdge?.layer?.removeAnimation(forKey: "slide")
        layer?.mask = nil
        barBand.removeFromSuperlayer()
        clipsToBounds = true
        panes.first.map { $0.frame = lonePageFrame }
        // The page's last layout may still be on its way; the pin lets go once it's in.
        pin.stop()
        CATransaction.commit()
    }

    private func layoutPanes() {
        if clearsSlideOnResize { clearSlide() }
        let frames = split.map { PaneStyle.frames(of: $0, in: bounds.size, gap: gap) }
        for view in subviews where view !== glassEdge {
            if let frames, let i = panes.firstIndex(where: { $0 === view }) {
                view.frame = frames[i]
                view.layer?.cornerRadius = radius
                view.layer?.cornerCurve = .continuous
                view.layer?.masksToBounds = true
            } else {
                view.frame = lonePageFrame
                view.layer?.cornerRadius = 0
            }
        }
        pin.update()
        // Until it starts moving, the edge stays put in the window as this view moves.
        if let slideEdge, edgeSeconds == 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeEdgeLayers(at: slideEdge, width: barBand.frame.width)
            CATransaction.commit()
        }
        if let opening, Self.same(reach, opening) { arrive() }
    }
}

/// Holds a WebKit page's drawing against its view's right edge until the page lays out for the
/// view's new width. A view that changes width every frame then never shows the page's right
/// side moving: WebKit keeps showing the last layout, from the left, until the next one lands.
///
/// WebKit's own "overhang areas" layer spans the layout on screen, beside any covered part, and
/// changes in the same commit as it, so watching it moves the drawing in step.
@MainActor
final class RightPin {
    private weak var page: NSView?
    private weak var clip: CALayer?
    private weak var root: CALayer?
    private var watch: NSKeyValueObservation?
    private var moved: NSKeyValueObservation?
    private static let laidOut = "overhang areas"
    private var holding = false
    private var color: CGColor?
    private var rootColor: CGColor?

    func start(_ page: NSView, color: CGColor) {
        if self.page !== page { release() }
        self.page = page
        self.color = color
        holding = true
        update()
    }

    /// Lets go once the page's layout matches its view.
    func stop() {
        holding = false
        update()
    }

    func update() {
        guard let page, let layer = page.layer else { return }
        guard let root = layer.sublayers?.first(where: { Self.find(Self.laidOut, in: $0) != nil }),
              let clip = Self.find(Self.laidOut, in: root) else { return }
        if clip !== self.clip {
            self.clip = clip
            watch = clip.observe(\.bounds) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            }
            moved = clip.observe(\.position) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        if root !== self.root {
            self.root = root
            rootColor = root.backgroundColor
        }
        var right = clip.bounds.width
        var step: CALayer? = clip
        while let current = step, current !== root {
            right += current.frame.minX
            step = current.superlayer
        }
        let shift = page.bounds.width - right
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayerTransform = CATransform3DMakeTranslation(shift, 0, 0)
        root.backgroundColor = holding ? color : rootColor
        CATransaction.commit()
        if !holding && abs(shift) < 0.5 { release() }
    }

    private func release() {
        if let root {
            root.sublayerTransform = CATransform3DIdentity
            root.backgroundColor = rootColor
        }
        watch = nil
        moved = nil
        clip = nil
        root = nil
        page = nil
    }

    private static func find(_ name: String, in layer: CALayer) -> CALayer? {
        if layer.name == name { return layer }
        for sub in layer.sublayers ?? [] {
            if let found = find(name, in: sub) { return found }
        }
        return nil
    }
}

