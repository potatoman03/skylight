import Foundation

/// Injected so the reducer stays deterministic in tests.
public struct ReducerEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var makeTabID: @Sendable () -> TabID
    public var makeSpaceID: @Sendable () -> SpaceID

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeTabID: @escaping @Sendable () -> TabID = { TabID() },
        makeSpaceID: @escaping @Sendable () -> SpaceID = { SpaceID() }
    ) {
        self.now = now
        self.makeTabID = makeTabID
        self.makeSpaceID = makeSpaceID
    }
}

/// Applies actions to `BrowserState` and lists the engine work they imply. No side effects.
public enum BrowserReducer {
    public static func reduce(_ state: inout BrowserState, _ action: BrowserAction, env: ReducerEnvironment) -> ReduceResult {
        switch action {
        case let .openTab(url, placement, select, spaceID):
            return openTab(&state, url: url, placement: placement, select: select, spaceID: spaceID, env: env)

        case let .closeTab(id):
            return closeTab(&state, id, now: env.now())

        case .reopenClosedTab:
            guard let closed = state.closedTabs.popLast() else { return .ignored }
            let spaceIndex = state.spaces.firstIndex { $0.id == closed.spaceID } ?? state.activeSpaceIndex
            var tab = closed.tab
            tab.lastActiveAt = env.now()
            state.tabs[tab.id] = tab
            let list = state.spaces[spaceIndex][closed.section]
            state.spaces[spaceIndex][closed.section].insert(tab.id, at: min(closed.index, list.count))
            state.spaces[spaceIndex].selectedTabID = tab.id
            state.activeSpaceID = state.spaces[spaceIndex].id
            return ReduceResult(effects: [.showTab(tab.id)], openedTabID: tab.id)

        case let .selectTab(id):
            guard let spaceIndex = state.spaceIndex(containing: id) else { return .ignored }
            state.spaces[spaceIndex].selectedTabID = id
            state.activeSpaceID = state.spaces[spaceIndex].id
            state.tabs[id]?.lastActiveAt = env.now()
            return ReduceResult(effects: [.showTab(id)])

        case let .selectAdjacentTab(offset):
            let ids = state.activeSpace.allTabIDs
            guard !ids.isEmpty else { return .ignored }
            let current = state.selectedTabID.flatMap { ids.firstIndex(of: $0) } ?? 0
            let next = ((current + offset) % ids.count + ids.count) % ids.count
            return reduce(&state, .selectTab(ids[next]), env: env)

        case let .navigate(id, url):
            guard state.tabs[id] != nil else { return .ignored }
            state.tabs[id]?.url = url
            state.tabs[id]?.lastActiveAt = env.now()
            return ReduceResult(effects: [.load(id, url)])

        case let .goBack(id):
            return state.tabs[id] == nil ? .ignored : ReduceResult(effects: [.goBack(id)])
        case let .goForward(id):
            return state.tabs[id] == nil ? .ignored : ReduceResult(effects: [.goForward(id)])
        case let .reload(id):
            return state.tabs[id] == nil ? .ignored : ReduceResult(effects: [.reload(id)])
        case let .stop(id):
            return state.tabs[id] == nil ? .ignored : ReduceResult(effects: [.stop(id)])

        case let .togglePin(id):
            guard let si = state.spaceIndex(containing: id), let section = state.spaces[si].section(of: id) else { return .ignored }
            state.spaces[si][section].removeAll { $0 == id }
            if section == .pinned {
                state.spaces[si].today.insert(id, at: 0)
            } else {
                state.spaces[si].pinned.append(id)
            }
            return ReduceResult()

        case let .moveTab(id, section, index):
            guard let si = state.spaceIndex(containing: id), let from = state.spaces[si].section(of: id) else { return .ignored }
            state.spaces[si][from].removeAll { $0 == id }
            let count = state.spaces[si][section].count
            state.spaces[si][section].insert(id, at: max(0, min(index, count)))
            return ReduceResult()

        case let .moveTabToSpace(id, spaceID):
            guard let from = state.spaceIndex(containing: id),
                  let to = state.spaces.firstIndex(where: { $0.id == spaceID }), from != to,
                  let tab = state.tabs[id] else { return .ignored }
            var result = closeTab(&state, id, remember: false, now: env.now())
            state.tabs[id] = tab
            state.spaces[to].today.insert(id, at: 0)
            state.spaces[to].selectedTabID = id
            state.activeSpaceID = spaceID
            // A different Space means a different cookie jar: the page must be rebuilt there.
            result.effects.append(contentsOf: [.discardPage(id), .showTab(id)])
            return result

        case let .createSpace(name, hue):
            let hues = state.spaces.map(\.hue)
            let space = Space(id: env.makeSpaceID(), name: name, hue: hue ?? nextHue(after: hues))
            state.spaces.append(space)
            state.activeSpaceID = space.id
            return ReduceResult(effects: [.showTab(nil)])

        case let .renameSpace(id, name):
            guard let i = state.spaces.firstIndex(where: { $0.id == id }) else { return .ignored }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .ignored }
            state.spaces[i].name = trimmed
            return ReduceResult()

        case let .deleteSpace(id):
            guard state.spaces.count > 1, let i = state.spaces.firstIndex(where: { $0.id == id }) else { return .ignored }
            let removed = state.spaces.remove(at: i)
            var effects = removed.allTabIDs.map { BrowserEffect.discardPage($0) }
            removed.allTabIDs.forEach { state.tabs[$0] = nil }
            state.closedTabs.removeAll { $0.spaceID == id }
            effects.append(.releaseSpace(id))
            if state.activeSpaceID == id {
                state.activeSpaceID = state.spaces[max(0, i - 1)].id
                effects.append(.showTab(state.selectedTabID))
            }
            return ReduceResult(effects: effects)

        case let .switchSpace(id):
            guard state.spaces.contains(where: { $0.id == id }) else { return .ignored }
            state.activeSpaceID = id
            if let sel = state.selectedTabID { state.tabs[sel]?.lastActiveAt = env.now() }
            return ReduceResult(effects: [.showTab(state.selectedTabID)])

        case let .switchSpaceByOffset(offset):
            let target = state.activeSpaceIndex + offset
            guard state.spaces.indices.contains(target) else { return .ignored }
            return reduce(&state, .switchSpace(state.spaces[target].id), env: env)

        case let .pageDidUpdate(id, meta):
            guard state.tabs[id] != nil else { return .ignored }
            if let url = meta.url { state.tabs[id]?.url = url }
            if let title = meta.title { state.tabs[id]?.title = title }
            if let icon = meta.faviconURL { state.tabs[id]?.faviconURL = icon }
            return ReduceResult()

        case let .archiveTabs(cutoff):
            let selected = state.selectedTabIDs
            var effects: [BrowserEffect] = []
            for space in state.spaces {
                for id in space.today where !selected.contains(id) {
                    if let tab = state.tabs[id], tab.lastActiveAt < cutoff {
                        effects += closeTab(&state, id, now: env.now()).effects
                    }
                }
            }
            return ReduceResult(effects: effects, applied: !effects.isEmpty)
        }
    }

    // MARK: - Helpers

    private static func openTab(_ state: inout BrowserState, url: URL, placement: BrowserAction.Placement,
                                select: Bool, spaceID: SpaceID?, env: ReducerEnvironment) -> ReduceResult {
        let si = spaceID.flatMap { id in state.spaces.firstIndex { $0.id == id } } ?? state.activeSpaceIndex
        let tab = Tab(id: env.makeTabID(), url: url, now: env.now())
        state.tabs[tab.id] = tab

        let today = state.spaces[si].today
        let index: Int
        switch placement {
        case .top: index = 0
        case .end: index = today.count
        case .afterSelected:
            if let sel = state.spaces[si].selectedTabID, let i = today.firstIndex(of: sel) { index = i + 1 } else { index = 0 }
        }
        state.spaces[si].today.insert(tab.id, at: index)

        var effects: [BrowserEffect] = [.load(tab.id, url)]
        if select {
            state.spaces[si].selectedTabID = tab.id
            state.activeSpaceID = state.spaces[si].id
            effects.append(.showTab(tab.id))
        }
        return ReduceResult(effects: effects, openedTabID: tab.id)
    }

    private static func closeTab(_ state: inout BrowserState, _ id: TabID, remember: Bool = true, now: Date = .now) -> ReduceResult {
        guard let si = state.spaceIndex(containing: id),
              let section = state.spaces[si].section(of: id),
              let tab = state.tabs[id] else { return .ignored }

        let order = state.spaces[si].allTabIDs
        let index = state.spaces[si][section].firstIndex(of: id) ?? 0
        state.spaces[si][section].remove(at: index)
        state.tabs[id] = nil

        if remember {
            state.closedTabs.append(ClosedTab(tab: tab, spaceID: state.spaces[si].id, section: section, index: index))
            if state.closedTabs.count > BrowserState.closedTabLimit { state.closedTabs.removeFirst() }
        }

        var effects: [BrowserEffect] = [.discardPage(id)]
        if state.spaces[si].selectedTabID == id {
            // Select the neighbor below, else above, like closing a row in a list.
            let pos = order.firstIndex(of: id) ?? 0
            let remaining = order.filter { $0 != id }
            let next = remaining.isEmpty ? nil : remaining[min(pos, remaining.count - 1)]
            state.spaces[si].selectedTabID = next
            if let next { state.tabs[next]?.lastActiveAt = now }
            if state.spaces[si].id == state.activeSpaceID { effects.append(.showTab(next)) }
        }
        return ReduceResult(effects: effects)
    }

    /// Picks a hue far from the ones already in use.
    static func nextHue(after hues: [Double]) -> Double {
        guard !hues.isEmpty else { return 0.09 }
        let candidates = stride(from: 0.0, to: 1.0, by: 1.0 / 24).map { $0 }
        func distance(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }
        return candidates.max { a, b in
            hues.map { distance($0, a) }.min()! < hues.map { distance($0, b) }.min()!
        }!
    }
}
