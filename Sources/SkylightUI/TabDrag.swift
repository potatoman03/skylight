import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// Tabs travel by the system's drag and drop, so they can land in the sidebar, on the page, on a
/// favorite or a Space button (which springs open), and the drag image is the system's.
///
/// The session also knows when a tab drag is under way, so the page can put a drop target over
/// the engine's view (which would otherwise take the drop as text).
@MainActor
@Observable
final class TabDragSession {
    enum Source: String { case row, pane }

    struct Payload: Equatable {
        let id: TabID
        /// A pane leaves its split; a sidebar row takes the whole split with it.
        let source: Source
    }

    private(set) var active: Payload?
    @ObservationIgnored private var timer: Timer?

    private static let prefix = "skylight-tab:"

    /// Starts dragging a tab.
    func provider(for id: TabID, source: Source) -> NSItemProvider {
        let payload = Payload(id: id, source: source)
        active = payload
        watchForEnd()
        return NSItemProvider(object: Self.encode(payload) as NSString)
    }

    static func encode(_ payload: Payload) -> String { "\(prefix)\(payload.source.rawValue):\(payload.id.rawValue)" }

    static func decode(_ string: String) -> Payload? {
        guard string.hasPrefix(prefix) else { return nil }
        let parts = string.dropFirst(prefix.count).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let source = Source(rawValue: String(parts[0])) else { return nil }
        return Payload(id: TabID(String(parts[1])), source: source)
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        active = nil
    }

    /// The system doesn't say when a drag ends without a drop; the mouse button does. The timer
    /// only runs in the default run loop mode, so it waits out the drag itself.
    private func watchForEnd() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.finish() }
            }
        }
    }
}

/// Where a dragged tab (or a link from elsewhere) can land.
enum TabDropTarget: Equatable {
    /// Before the `row`th sidebar row of a section (a split is one row).
    case section(SkylightCore.TabSection, row: Int)
    case favorites(index: Int)
    case space(SpaceID)
    case split(TabID, SplitEdge)
    /// Into a folder, before its `index`th tab.
    case folder(String, index: Int)
}

extension Browser {
    /// Drops what was dragged (tabs, or links from a page or another app) on `target`.
    @discardableResult
    func drop(_ items: [String], on target: TabDropTarget) -> Bool {
        guard let item = items.first else { return false }
        if let payload = TabDragSession.decode(item) { return drop(payload, on: target) }
        // A link: open it there.
        guard let url = URL(string: item.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""),
              let id = store.send(.openTab(url, placement: .end)).openedTabID else { return false }
        return drop(TabDragSession.Payload(id: id, source: .row), on: target)
    }

    /// Unanimated when the sidebar has already made room for the tab where it lands.
    @discardableResult
    func drop(_ payload: TabDragSession.Payload, on target: TabDropTarget, animated: Bool = true) -> Bool {
        let id = payload.id
        let state = store.state
        guard state.tabs[id] != nil else { return false }
        var applied = false
        let move = { [self] in
            switch target {
            case let .section(section, row):
                if payload.source == .pane { store.send(.leaveSplit(id)) }
                let state = store.state
                if !state.isFavorite(id), state.space(containing: id)?.id != state.activeSpaceID {
                    store.send(.moveTabToSpace(id, state.activeSpaceID))
                }
                if store.state.activeSpace.folder(containing: id) != nil { store.send(.moveTabToFolder(id, folder: nil)) }
                let space = store.state.activeSpace
                let moving = Set(store.state.isFavorite(id) ? [id] : space.group(of: id))
                let index: Int
                if section == .pinned {
                    // Folders' tabs are pinned too, but listed apart: land before the next loose row.
                    let next = SidebarRows.make(space.loosePinned, space: space).dropFirst(row).first { !$0.contains(where: moving.contains) }
                    let pinned = space.pinned.filter { !moving.contains($0) }
                    index = next.flatMap { pinned.firstIndex(of: $0[0]) } ?? pinned.count
                } else {
                    // Rows before the drop point, counted in tabs, leaving out what's moving.
                    index = SidebarRows.make(space[section], space: space).prefix(row)
                        .filter { !$0.contains(where: moving.contains) }
                        .reduce(0) { $0 + $1.count }
                }
                applied = store.send(.moveTab(id, to: section, index: index)).applied
            case let .favorites(index):
                let others = state.favorites.filter { $0 != id }
                let before = state.favorites.prefix(index).filter { $0 != id }.count
                applied = store.send(.moveToFavorites(id, index: min(before, others.count))).applied
            case let .folder(folderID, index):
                // The list counts the tab where it is now; the reducer takes it out first.
                let current = state.spaces.lazy.flatMap(\.folders).first { $0.id == folderID }?.tabs.firstIndex(of: id)
                let target = current.map { $0 < index ? index - 1 : index } ?? index
                applied = store.send(.moveTabToFolder(id, folder: folderID, index: target)).applied
            case let .space(spaceID):
                applied = store.send(.moveTabToSpace(id, spaceID)).applied
            case let .split(tab, edge):
                if let split = state.activeSpace.split(containing: tab), let from = split.tabs.firstIndex(of: id),
                   let to = split.tabs.firstIndex(of: tab) {
                    // Rearranging the panes of one split.
                    let index = edge.isAfter ? (from < to ? to : to + 1) : (from < to ? to - 1 : to)
                    applied = store.send(.movePane(id, to: index)).applied
                } else {
                    applied = store.send(.splitTab(id, beside: tab, edge: edge)).applied
                }
            }
        }
        if animated { animate(Motion.travel, move) } else { move() }
        return applied
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
    /// Makes a tab draggable, with a small label of it as the drag image.
    func tabDrag(_ tab: SkylightCore.Tab, source: TabDragSession.Source, session: TabDragSession) -> some View {
        onDrag {
            session.provider(for: tab.id, source: source)
        } preview: {
            // Nothing: the system can't change a drag's image midway, so the sidebar draws the
            // tab itself (hiding it over a split it's previewing), and the page shows its plan.
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
