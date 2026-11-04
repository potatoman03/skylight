import Foundation

/// Injected so the reducer stays deterministic in tests.
public struct ReducerEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var makeTabID: @Sendable () -> TabID
    public var makeSpaceID: @Sendable () -> SpaceID
    public var makeProfileID: @Sendable () -> ProfileID

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeTabID: @escaping @Sendable () -> TabID = { TabID() },
        makeSpaceID: @escaping @Sendable () -> SpaceID = { SpaceID() },
        makeProfileID: @escaping @Sendable () -> ProfileID = { ProfileID() }
    ) {
        self.now = now
        self.makeTabID = makeTabID
        self.makeSpaceID = makeSpaceID
        self.makeProfileID = makeProfileID
    }
}

/// Applies actions to `BrowserState` and lists the engine work they imply. No side effects.
public enum BrowserReducer {
    public static func reduce(_ state: inout BrowserState, _ action: BrowserAction, env: ReducerEnvironment) -> ReduceResult {
        let result = apply(&state, action, env: env)
        if result.applied { pruneFolders(&state) }
        return result
    }

    private static func apply(_ state: inout BrowserState, _ action: BrowserAction, env: ReducerEnvironment) -> ReduceResult {
        switch action {
        case let .openTab(url, placement, select, spaceID):
            return openTab(&state, url: url, placement: placement, select: select, spaceID: spaceID, env: env)

        case let .closeTab(id):
            return closeTab(&state, id, now: env.now())

        case let .removeTab(id):
            leaveSplits(&state, id)
            if state.isFavorite(id) {
                state.favorites.removeAll { $0 == id }
                state.spaces[state.activeSpaceIndex].today.insert(id, at: 0)
            }
            return closeTab(&state, id, unloadPinned: false, now: env.now())

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
            // A favorite opens in whichever Space is active.
            let spaceIndex = state.isFavorite(id) ? state.activeSpaceIndex : state.spaceIndex(containing: id)
            guard let spaceIndex else { return .ignored }
            state.spaces[spaceIndex].selectedTabID = id
            state.activeSpaceID = state.spaces[spaceIndex].id
            state.tabs[id]?.lastActiveAt = env.now()
            return ReduceResult(effects: [.showTab(id)])

        case let .selectAdjacentTab(offset):
            let ids = state.favorites + state.activeSpace.allTabIDs
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
            leaveSplits(&state, id)
            if state.isFavorite(id) {
                state.favorites.removeAll { $0 == id }
                state.spaces[state.activeSpaceIndex].pinned.append(id)
                return ReduceResult()
            }
            guard let si = state.spaceIndex(containing: id), let section = state.spaces[si].section(of: id) else { return .ignored }
            state.spaces[si][section].removeAll { $0 == id }
            if section == .pinned {
                state.spaces[si].today.insert(id, at: 0)
            } else {
                state.spaces[si].pinned.append(id)
            }
            return ReduceResult()

        case let .toggleFavorite(id):
            guard state.tabs[id] != nil else { return .ignored }
            leaveSplits(&state, id)
            if state.isFavorite(id) {
                state.favorites.removeAll { $0 == id }
                state.spaces[state.activeSpaceIndex].today.insert(id, at: 0)
            } else {
                guard let si = state.spaceIndex(containing: id), let section = state.spaces[si].section(of: id) else { return .ignored }
                state.spaces[si][section].removeAll { $0 == id }
                state.favorites.append(id)
                // Keep it selected where the user is looking.
                if state.spaces[si].selectedTabID == id, si != state.activeSpaceIndex { state.spaces[si].selectedTabID = nil }
            }
            return ReduceResult()

        case .clearToday:
            let si = state.activeSpaceIndex
            let selected = state.spaces[si].selectedTabID
            var effects: [BrowserEffect] = []
            for id in state.spaces[si].today where id != selected {
                effects += closeTab(&state, id, now: env.now()).effects
            }
            return ReduceResult(effects: effects, applied: !effects.isEmpty)

        case let .moveTab(id, section, index):
            if state.isFavorite(id) {
                state.favorites.removeAll { $0 == id }
                let si = state.activeSpaceIndex
                state.spaces[si][section].insert(id, at: max(0, min(index, state.spaces[si][section].count)))
                return ReduceResult()
            }
            guard let si = state.spaceIndex(containing: id), state.spaces[si].section(of: id) != nil else { return .ignored }
            // A split moves as one row. `index` counts the destination without the moved tabs.
            let group = state.spaces[si].group(of: id)
            for section in TabSection.allCases { state.spaces[si][section].removeAll { group.contains($0) } }
            let count = state.spaces[si][section].count
            state.spaces[si][section].insert(contentsOf: group, at: max(0, min(index, count)))
            return ReduceResult()

        case let .moveToFavorites(id, index):
            guard state.tabs[id] != nil else { return .ignored }
            leaveSplits(&state, id)
            if let si = state.spaceIndex(containing: id) {
                for section in TabSection.allCases { state.spaces[si][section].removeAll { $0 == id } }
                if state.spaces[si].selectedTabID == id, si != state.activeSpaceIndex { state.spaces[si].selectedTabID = nil }
            }
            state.favorites.removeAll { $0 == id }
            state.favorites.insert(id, at: max(0, min(index, state.favorites.count)))
            return ReduceResult()

        case let .splitTab(id, target, edge):
            return splitTab(&state, id, beside: target, edge: edge, env: env)

        case let .leaveSplit(id):
            guard let si = state.spaceIndex(containing: id), state.spaces[si].split(containing: id) != nil else { return .ignored }
            leaveSplits(&state, id)
            return relayout(state, si)

        case let .dissolveSplit(id):
            guard let si = state.spaceIndex(containing: id), let k = state.spaces[si].splitIndex(containing: id) else { return .ignored }
            state.spaces[si].splits.remove(at: k)
            return relayout(state, si)

        case let .resizeSplit(id, fractions):
            guard let si = state.spaceIndex(containing: id), let k = state.spaces[si].splitIndex(containing: id),
                  fractions.count == state.spaces[si].splits[k].tabs.count else { return .ignored }
            state.spaces[si].splits[k].fractions = fractions
            state.spaces[si].splits[k].normalize()
            return relayout(state, si)

        case let .rotateSplit(id):
            guard let si = state.spaceIndex(containing: id), let k = state.spaces[si].splitIndex(containing: id) else { return .ignored }
            state.spaces[si].splits[k].axis = state.spaces[si].splits[k].axis.flipped
            return relayout(state, si)

        case let .movePane(id, to):
            guard let si = state.spaceIndex(containing: id), let k = state.spaces[si].splitIndex(containing: id),
                  let from = state.spaces[si].splits[k].tabs.firstIndex(of: id) else { return .ignored }
            var split = state.spaces[si].splits[k]
            let fraction = split.fractions.remove(at: from)
            split.tabs.remove(at: from)
            let index = max(0, min(to, split.tabs.count))
            split.tabs.insert(id, at: index)
            split.fractions.insert(fraction, at: index)
            state.spaces[si].splits[k] = split
            return relayout(state, si)

        case let .moveTabToSpace(id, spaceID):
            guard let from = state.spaceIndex(containing: id),
                  let to = state.spaces.firstIndex(where: { $0.id == spaceID }), from != to,
                  let tab = state.tabs[id] else { return .ignored }
            let sameProfile = state.spaces[from].profileID == state.spaces[to].profileID
            leaveSplits(&state, id)
            var result = closeTab(&state, id, remember: false, unloadPinned: false, now: env.now())
            state.tabs[id] = tab
            state.spaces[to].today.insert(id, at: 0)
            state.spaces[to].selectedTabID = id
            state.activeSpaceID = spaceID
            // A different profile means a different cookie jar: the page must be rebuilt there.
            result.effects.removeAll { $0 == .discardPage(id) }
            if !sameProfile { result.effects.append(.discardPage(id)) }
            result.effects.append(.showTab(id))
            return result

        case let .createFolder(id, spaceID, name, tabs):
            guard let si = state.spaces.firstIndex(where: { $0.id == spaceID }) else { return .ignored }
            state.spaces[si].folders.append(TabFolder(id: id, name: name))
            for tab in tabs { _ = apply(&state, .moveTabToFolder(tab, folder: id), env: env) }
            return ReduceResult()

        case let .renameFolder(id, name):
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let (si, k) = folderIndex(state, id) else { return .ignored }
            state.spaces[si].folders[k].name = name
            return ReduceResult()

        case let .deleteFolder(id, closeTabs):
            guard let (si, k) = folderIndex(state, id) else { return .ignored }
            let folder = state.spaces[si].folders.remove(at: k)
            var result = ReduceResult()
            if closeTabs {
                for tab in folder.tabs { result.effects += apply(&state, .removeTab(tab), env: env).effects }
            }
            return result

        case let .setFolderOpen(id, open):
            guard let (si, k) = folderIndex(state, id), state.spaces[si].folders[k].isOpen != open else { return .ignored }
            state.spaces[si].folders[k].isOpen = open
            return ReduceResult()

        case let .moveFolder(id, index):
            guard let (si, k) = folderIndex(state, id) else { return .ignored }
            let folder = state.spaces[si].folders.remove(at: k)
            state.spaces[si].folders.insert(folder, at: max(0, min(index, state.spaces[si].folders.count)))
            return ReduceResult()

        case let .moveTabToFolder(id, folderID, index):
            guard state.tabs[id] != nil else { return .ignored }
            guard let folderID else {
                guard let si = state.spaceIndex(containing: id), let k = state.spaces[si].folders.firstIndex(where: { $0.tabs.contains(id) })
                else { return .ignored }
                state.spaces[si].folders[k].tabs.removeAll { $0 == id }
                return ReduceResult()
            }
            guard let (si, _) = folderIndex(state, folderID) else { return .ignored }
            // Folders hold pinned tabs of their own Space, one pane at a time.
            leaveSplits(&state, id)
            if state.isFavorite(id) {
                state.favorites.removeAll { $0 == id }
            } else if let from = state.spaceIndex(containing: id) {
                state.spaces[from].pinned.removeAll { $0 == id }
                state.spaces[from].today.removeAll { $0 == id }
                if state.spaces[from].selectedTabID == id, from != si { state.spaces[from].selectedTabID = nil }
            }
            state.spaces[si].pinned.append(id)
            for f in state.spaces[si].folders.indices { state.spaces[si].folders[f].tabs.removeAll { $0 == id } }
            let k = state.spaces[si].folders.firstIndex { $0.id == folderID }!
            let tabs = state.spaces[si].folders[k].tabs
            state.spaces[si].folders[k].tabs.insert(id, at: max(0, min(index, tabs.count)))
            return ReduceResult()

        case let .createSpace(name, hue):
            let hues = state.spaces.map(\.hue)
            let space = Space(id: env.makeSpaceID(), name: name, hue: hue ?? nextHue(after: hues), profileID: state.activeSpace.profileID)
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

        case let .setSpaceHue(id, hue):
            guard let i = state.spaces.firstIndex(where: { $0.id == id }) else { return .ignored }
            state.spaces[i].hue = hue - floor(hue)
            return ReduceResult()

        case let .setSpaceIcon(id, icon):
            guard let i = state.spaces.firstIndex(where: { $0.id == id }) else { return .ignored }
            state.spaces[i].icon = icon.flatMap { $0.isEmpty ? nil : $0 }
            return ReduceResult()

        case let .setSpaceTheme(id, theme):
            guard let i = state.spaces.firstIndex(where: { $0.id == id }) else { return .ignored }
            state.spaces[i].themeID = theme
            return ReduceResult()

        case let .assignProfile(spaceID, profileID):
            guard let i = state.spaces.firstIndex(where: { $0.id == spaceID }), state.profile(profileID) != nil,
                  state.spaces[i].profileID != profileID else { return .ignored }
            state.spaces[i].profileID = profileID
            var effects = state.spaces[i].allTabIDs.map(BrowserEffect.discardPage)
            if i == state.activeSpaceIndex {
                if let sel = state.selectedTabID, state.isFavorite(sel) { effects.append(.discardPage(sel)) }
                effects.append(.showTab(state.selectedTabID))
            }
            return ReduceResult(effects: effects)

        case let .createProfile(name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .ignored }
            state.profiles.append(Profile(id: env.makeProfileID(), name: trimmed))
            return ReduceResult()

        case let .renameProfile(id, name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let i = state.profiles.firstIndex(where: { $0.id == id }), !trimmed.isEmpty else { return .ignored }
            state.profiles[i].name = trimmed
            return ReduceResult()

        case let .setProfileIcon(id, icon):
            guard let i = state.profiles.firstIndex(where: { $0.id == id }) else { return .ignored }
            state.profiles[i].icon = icon.flatMap { $0.isEmpty ? nil : $0 }
            return ReduceResult()

        case let .setProfileHue(id, hue):
            guard let i = state.profiles.firstIndex(where: { $0.id == id }) else { return .ignored }
            state.profiles[i].hue = hue.map { $0 - floor($0) }
            return ReduceResult()

        case let .deleteProfile(id):
            guard id != .standard, state.profile(id) != nil else { return .ignored }
            var effects: [BrowserEffect] = []
            for i in state.spaces.indices where state.spaces[i].profileID == id {
                effects += reduce(&state, .assignProfile(state.spaces[i].id, .standard), env: env).effects
            }
            state.profiles.removeAll { $0.id == id }
            effects.append(.releaseProfile(id))
            return ReduceResult(effects: effects)

        case let .importBrowserData(data):
            guard !data.isEmpty else { return .ignored }
            let now = env.now()
            var known = Set(state.tabs.values.map(\.url))
            func add(_ link: BrowserImport.Link) -> TabID? {
                guard known.insert(link.url).inserted else { return nil }
                let tab = Tab(id: env.makeTabID(), url: link.url, title: link.title, now: now)
                state.tabs[tab.id] = tab
                return tab.id
            }
            state.favorites += data.favorites.compactMap(add)
            for imported in data.spaces where !imported.pinned.isEmpty {
                let pinned = imported.pinned.compactMap(add)
                guard !pinned.isEmpty else { continue }
                if let i = state.spaces.firstIndex(where: { $0.name.caseInsensitiveCompare(imported.name) == .orderedSame }) {
                    state.spaces[i].pinned += pinned
                } else {
                    state.spaces.append(Space(id: env.makeSpaceID(), name: imported.name,
                                              hue: imported.hue ?? nextHue(after: state.spaces.map(\.hue)),
                                              icon: imported.icon, profileID: state.activeSpace.profileID, pinned: pinned))
                }
            }
            return ReduceResult()

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

    private static func closeTab(_ state: inout BrowserState, _ id: TabID, remember: Bool = true, unloadPinned: Bool = true,
                                 now: Date = .now) -> ReduceResult {
        // Closing a pane leaves its split; focus stays in what's left of it.
        let partner = state.space(containing: id)?.split(containing: id)?.tabs.first { $0 != id }
        leaveSplits(&state, id)
        // Closing a favorite or a pinned tab only puts it to sleep; it stays where it is.
        let keep = state.isFavorite(id) || (unloadPinned && state.space(containing: id)?.section(of: id) == .pinned)
        if keep {
            var effects: [BrowserEffect] = [.discardPage(id)]
            for si in state.spaces.indices where state.spaces[si].selectedTabID == id {
                // Fall to a Today tab rather than waking another pinned one.
                let next = partner ?? state.spaces[si].today.first
                state.spaces[si].selectedTabID = next
                if si == state.activeSpaceIndex { effects.append(.showTab(next)) }
            }
            return ReduceResult(effects: effects)
        }
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
            let next = partner ?? (remaining.isEmpty ? nil : remaining[min(pos, remaining.count - 1)])
            state.spaces[si].selectedTabID = next
            if let next { state.tabs[next]?.lastActiveAt = now }
            if state.spaces[si].id == state.activeSpaceID { effects.append(.showTab(next)) }
        }
        return ReduceResult(effects: effects)
    }

    // MARK: - Splits

    private static func splitTab(_ state: inout BrowserState, _ id: TabID, beside target: TabID, edge: SplitEdge,
                                 env: ReducerEnvironment) -> ReduceResult {
        guard id != target, state.tabs[id] != nil, state.tabs[target] != nil else { return .ignored }
        // A favorite target joins the active Space, where it's showing.
        if state.isFavorite(target) {
            state.favorites.removeAll { $0 == target }
            state.spaces[state.activeSpaceIndex].today.insert(target, at: 0)
        }
        guard let si = state.spaceIndex(containing: target), let section = state.spaces[si].section(of: target) else { return .ignored }
        if let k = state.spaces[si].splitIndex(containing: target), !state.spaces[si].splits[k].tabs.contains(id) {
            let split = state.spaces[si].splits[k]
            guard split.tabs.count < TabSplit.maxPanes, split.axis == edge.axis else { return .ignored }
        }

        var effects: [BrowserEffect] = []
        let fromSpace = state.spaceIndex(containing: id)
        if let from = fromSpace, state.spaces[from].profileID != state.spaces[si].profileID { effects.append(.discardPage(id)) }
        leaveSplits(&state, id)
        state.favorites.removeAll { $0 == id }
        if let from = fromSpace {
            for s in TabSection.allCases { state.spaces[from][s].removeAll { $0 == id } }
            if from != si, state.spaces[from].selectedTabID == id { state.spaces[from].selectedTabID = nil }
        }

        // The new pane sits next to the target in the sidebar too.
        let at = state.spaces[si][section].firstIndex(of: target) ?? 0
        state.spaces[si][section].insert(id, at: edge.isAfter ? at + 1 : at)

        if let k = state.spaces[si].splitIndex(containing: target) {
            var split = state.spaces[si].splits[k]
            let pane = split.tabs.firstIndex(of: target) ?? 0
            // The new pane takes half of the one it lands beside.
            let half = split.fractions[pane] / 2
            split.fractions[pane] = half
            let index = edge.isAfter ? pane + 1 : pane
            split.tabs.insert(id, at: index)
            split.fractions.insert(half, at: index)
            split.normalize()
            state.spaces[si].splits[k] = split
        } else {
            state.spaces[si].splits.append(TabSplit(tabs: edge.isAfter ? [target, id] : [id, target], axis: edge.axis))
        }
        state.spaces[si].selectedTabID = id
        state.activeSpaceID = state.spaces[si].id
        state.tabs[id]?.lastActiveAt = env.now()
        effects.append(.showTab(id))
        return ReduceResult(effects: effects)
    }

    private static func folderIndex(_ state: BrowserState, _ id: String) -> (Int, Int)? {
        for si in state.spaces.indices {
            if let k = state.spaces[si].folders.firstIndex(where: { $0.id == id }) { return (si, k) }
        }
        return nil
    }

    /// A tab that stops being pinned (unpinned, moved, closed for good) leaves its folder.
    private static func pruneFolders(_ state: inout BrowserState) {
        for si in state.spaces.indices where !state.spaces[si].folders.isEmpty {
            let pinned = Set(state.spaces[si].pinned)
            for k in state.spaces[si].folders.indices where state.spaces[si].folders[k].tabs.contains(where: { !pinned.contains($0) }) {
                state.spaces[si].folders[k].tabs.removeAll { !pinned.contains($0) }
            }
        }
    }

    /// Takes a tab out of whichever split holds it; splits left with one pane go away.
    private static func leaveSplits(_ state: inout BrowserState, _ id: TabID) {
        for si in state.spaces.indices {
            guard let k = state.spaces[si].splitIndex(containing: id) else { continue }
            var split = state.spaces[si].splits[k]
            let pane = split.tabs.firstIndex(of: id)!
            split.tabs.remove(at: pane)
            split.fractions.remove(at: pane)
            if split.tabs.count < 2 {
                state.spaces[si].splits.remove(at: k)
            } else {
                split.normalize()
                state.spaces[si].splits[k] = split
            }
        }
    }

    /// The panes on screen changed shape: show the selection again.
    private static func relayout(_ state: BrowserState, _ si: Int) -> ReduceResult {
        si == state.activeSpaceIndex ? ReduceResult(effects: [.showTab(state.selectedTabID)]) : ReduceResult()
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
