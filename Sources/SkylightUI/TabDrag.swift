import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// Dragging tabs around the window: reordering in the sidebar, pinning, favoriting, moving to
/// another Space, and dropping onto the page to split it.
///
/// It's one gesture the window tracks itself (not system drag and drop), so the sidebar can make
/// room as you go and the page can preview where a split will land. Views report where they are
/// in the window's coordinate space; this works out what's under the pointer.
@MainActor
@Observable
final class TabDrag {
    static let space = "skylight.window"

    enum Source: Equatable { case sidebar, favorite, pane }

    struct Item: Equatable {
        let id: TabID
        /// The tabs that move with it: a split's panes move as one row.
        let group: [TabID]
        let source: Source
    }

    enum Target: Equatable {
        case section(SkylightCore.TabSection, index: Int)
        case favorites(index: Int)
        case space(SpaceID)
        case split(TabID, SplitEdge)
    }

    private(set) var item: Item?
    private(set) var location: CGPoint = .zero
    private(set) var target: Target?

    // Geometry, reported by views. Not observed: it changes on every layout.
    @ObservationIgnored var sectionFrames: [SkylightCore.TabSection: CGRect] = [:]
    /// Where each section's first row starts.
    @ObservationIgnored var listTops: [SkylightCore.TabSection: CGFloat] = [:]
    @ObservationIgnored var rowPitch: CGFloat = 38
    @ObservationIgnored var favoritesFrame: CGRect = .zero
    @ObservationIgnored var favoriteTiles: [TabID: CGRect] = [:]
    @ObservationIgnored var spaceButtons: [SpaceID: CGRect] = [:]
    @ObservationIgnored var contentFrame: CGRect = .zero
    /// The panes on screen, in the window's coordinates.
    @ObservationIgnored var panes: [(tab: TabID, frame: CGRect)] = []

    @ObservationIgnored private var browser: Browser?
    @ObservationIgnored private var springTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?

    var isDragging: Bool { item != nil }

    func begin(_ id: TabID, source: Source, browser: Browser) {
        guard item == nil else { return }
        self.browser = browser
        let state = browser.store.state
        let group = source == .pane ? [id] : (state.space(containing: id)?.group(of: id) ?? [id])
        item = Item(id: id, group: group, source: source)
        // Follow the mouse directly: the row that started the drag may go away mid-drag
        // (switching Spaces), which would end its gesture.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseUp: self.end()
                case .keyDown where event.keyCode == 53: self.cancel()  // Escape
                case .leftMouseDragged:
                    if let height = event.window?.contentView?.bounds.height {
                        self.move(to: CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y))
                    }
                default: break
                }
            }
            return event
        }
    }

    func move(to point: CGPoint) {
        guard item != nil else { return }
        location = point
        let next = resolve(point)
        if next != target {
            animate(Motion.travel) { target = next }
            springLoad(next)
        }
    }

    func end() {
        springTask?.cancel()
        defer { reset() }
        guard let item, let target, let browser else { return }
        let store = browser.store
        let state = store.state
        animate(Motion.travel) {
            switch target {
            case let .section(section, index):
                if item.source == .pane { store.send(.leaveSplit(item.id)) }
                if !state.isFavorite(item.id), state.space(containing: item.id)?.id != state.activeSpaceID {
                    store.send(.moveTabToSpace(item.id, state.activeSpaceID))
                }
                store.send(.moveTab(item.id, to: section, index: index))
            case let .favorites(index):
                store.send(.moveToFavorites(item.id, index: index))
            case let .space(id):
                store.send(.moveTabToSpace(item.id, id))
            case let .split(tab, edge):
                let split = state.activeSpace.split(containing: tab)
                if let split, let from = split.tabs.firstIndex(of: item.id), let to = split.tabs.firstIndex(of: tab) {
                    // Rearranging panes of the same split.
                    let index = edge.isAfter ? (from < to ? to : to + 1) : (from < to ? to - 1 : to)
                    store.send(.movePane(item.id, to: index))
                } else {
                    store.send(.splitTab(item.id, beside: tab, edge: edge))
                }
            }
        }
    }

    func cancel() {
        springTask?.cancel()
        reset()
    }

    private func reset() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        animate(Motion.travel) {
            item = nil
            target = nil
        }
    }

    /// Holding a tab over a Space's button switches to that Space, so you can place it there.
    private func springLoad(_ target: Target?) {
        springTask?.cancel()
        guard case let .space(id)? = target, let browser else { return }
        springTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, self.target == .space(id) else { return }
            animate(Motion.swap) { _ = browser.store.send(.switchSpace(id)) }
        }
    }

    // MARK: - Hit testing

    private func resolve(_ p: CGPoint) -> Target? {
        guard let item, let browser else { return nil }
        let state = browser.store.state

        if let (id, _) = spaceButtons.first(where: { $0.value.insetBy(dx: -2, dy: -4).contains(p) }) {
            return state.space(containing: item.id)?.id == id && state.activeSpaceID == id ? nil : .space(id)
        }

        if contentFrame.contains(p) { return splitTarget(at: p, item: item, state: state) }

        if favoritesFrame.insetBy(dx: 0, dy: -6).contains(p), item.group.count == 1 {
            return .favorites(index: favoriteIndex(at: p, excluding: item.id))
        }

        for section in [SkylightCore.TabSection.pinned, .today] {
            guard let frame = sectionFrames[section], frame.insetBy(dx: -4, dy: -6).contains(p) else { continue }
            return .section(section, index: rowIndex(at: p, in: section, state: state, item: item))
        }
        return nil
    }

    /// Rows are the same height, so the slot under the pointer is arithmetic. Positions count
    /// rows; the reducer wants tabs, so each split row before the slot counts all its panes.
    private func rowIndex(at p: CGPoint, in section: SkylightCore.TabSection, state: BrowserState, item: Item) -> Int {
        let space = state.activeSpace
        let rows = SidebarRows.make(space[section], space: space).filter { !$0.contains(item.id) }
        let top = listTops[section] ?? sectionFrames[section]?.minY ?? p.y
        // Upper half of a row: before it. Lower half: after it.
        let slot = max(0, min(rows.count, Int(((p.y - top) / rowPitch).rounded())))
        return rows.prefix(slot).reduce(0) { $0 + $1.count }
    }

    private func favoriteIndex(at p: CGPoint, excluding id: TabID) -> Int {
        let tiles = favoriteTiles.filter { $0.key != id }.values
        return tiles.filter { tile in tile.maxY < p.y || (tile.minY <= p.y && tile.midX < p.x) }.count
    }

    private func splitTarget(at p: CGPoint, item: Item, state: BrowserState) -> Target? {
        let visible = panes.isEmpty ? state.visibleTabIDs.map { ($0, contentFrame) } : panes
        guard let (tab, frame) = visible.first(where: { $0.1.contains(p) }) ?? visible.first, tab != item.id else { return nil }
        let split = state.activeSpace.split(containing: tab)
        let inSplit = split?.tabs.contains(item.id) == true
        // Settings and other built-in pages can't share the card.
        if state.tabs[item.id]?.url.isSkylightPage == true || state.tabs[tab]?.url.isSkylightPage == true { return nil }
        if let split, !inSplit, split.tabs.count >= TabSplit.maxPanes { return nil }
        if item.group.count > 1 { return nil }
        let x = (p.x - frame.minX) / max(frame.width, 1), y = (p.y - frame.minY) / max(frame.height, 1)
        if let split, split.tabs.count > 1 || inSplit {
            return split.axis == .horizontal ? .split(tab, x < 0.5 ? .leading : .trailing) : .split(tab, y < 0.5 ? .top : .bottom)
        }
        let edges: [(SplitEdge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        // Side by side is the common case: it wins unless the pointer is clearly near the top or bottom.
        let nearest = edges.min { a, b in
            (a.0.axis == .vertical ? a.1 * 1.6 : a.1) < (b.0.axis == .vertical ? b.1 * 1.6 : b.1)
        }!
        return .split(tab, nearest.0)
    }
}

/// The sidebar's rows: one per tab, except a split, which is one row for all its panes.
enum SidebarRows {
    static func make(_ ids: [TabID], space: Space) -> [[TabID]] {
        var seen = Set<TabID>()
        var rows: [[TabID]] = []
        for id in ids where !seen.contains(id) {
            let group = space.group(of: id).filter { ids.contains($0) }
            seen.formUnion(group)
            rows.append(group)
        }
        return rows
    }
}

extension View {
    /// Reports this view's frame in the window to `report`.
    func reportFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TabDrag.space)) } action: { report($0) }
    }

    /// Makes a tab draggable around the window.
    func tabDrag(_ id: TabID, source: TabDrag.Source, drag: TabDrag, browser: Browser) -> some View {
        gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(TabDrag.space))
                .onChanged { value in
                    if !drag.isDragging { drag.begin(id, source: source, browser: browser) }
                    drag.move(to: value.location)
                }
                .onEnded { _ in if drag.isDragging { drag.end() } }
        )
    }
}
