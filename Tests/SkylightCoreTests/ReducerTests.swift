import Foundation
import Testing
@testable import SkylightCore

/// Deterministic ids and clock.
private func environment() -> ReducerEnvironment {
    let counter = Counter()
    return ReducerEnvironment(
        now: { Date(timeIntervalSince1970: 1_000_000) },
        makeTabID: { TabID("t\(counter.next())") },
        makeSpaceID: { SpaceID("s\(counter.next())") },
        makeProfileID: { ProfileID("p\(counter.next())") })
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private let a = URL(string: "https://a.example")!
private let b = URL(string: "https://b.example")!
private let c = URL(string: "https://c.example")!

@Suite struct ReducerTests {
    let env = environment()

    func open(_ state: inout BrowserState, _ urls: URL...) -> [TabID] {
        urls.map { BrowserReducer.reduce(&state, .openTab($0), env: env).openedTabID! }
    }

    @Test func openTabSelectsAndInsertsAfterSelected() {
        var state = BrowserState.initial()
        let ids = open(&state, a, b)
        #expect(state.activeSpace.today == ids)
        #expect(state.selectedTabID == ids[1])

        BrowserReducer.reduce(&state, .selectTab(ids[0]), env: env)
        let result = BrowserReducer.reduce(&state, .openTab(c), env: env)
        #expect(state.activeSpace.today == [ids[0], result.openedTabID!, ids[1]])
        #expect(result.effects == [.load(result.openedTabID!, c), .showTab(result.openedTabID!)])
    }

    @Test func backgroundTabDoesNotChangeSelection() {
        var state = BrowserState.initial()
        let first = open(&state, a)[0]
        let result = BrowserReducer.reduce(&state, .openTab(b, select: false), env: env)
        #expect(state.selectedTabID == first)
        #expect(result.effects == [.load(result.openedTabID!, b)])
    }

    @Test func closingSelectsNeighborBelowThenAbove() {
        var state = BrowserState.initial()
        let ids = open(&state, a, b, c)
        BrowserReducer.reduce(&state, .selectTab(ids[1]), env: env)

        let result = BrowserReducer.reduce(&state, .closeTab(ids[1]), env: env)
        #expect(state.selectedTabID == ids[2])
        #expect(result.effects == [.discardPage(ids[1]), .showTab(ids[2])])

        BrowserReducer.reduce(&state, .closeTab(ids[2]), env: env)
        #expect(state.selectedTabID == ids[0])
    }

    @Test func reopenRestoresPosition() {
        var state = BrowserState.initial()
        let ids = open(&state, a, b, c)
        BrowserReducer.reduce(&state, .closeTab(ids[1]), env: env)
        let result = BrowserReducer.reduce(&state, .reopenClosedTab, env: env)
        #expect(state.activeSpace.today.count == 3)
        #expect(state.activeSpace.today[1] == result.openedTabID)
        #expect(state.tabs[result.openedTabID!]?.url == b)
        #expect(state.closedTabs.isEmpty)
    }

    @Test func pinMovesBetweenSections() {
        var state = BrowserState.initial()
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .togglePin(id), env: env)
        #expect(state.activeSpace.pinned == [id])
        #expect(state.activeSpace.today.isEmpty)
        BrowserReducer.reduce(&state, .togglePin(id), env: env)
        #expect(state.activeSpace.today == [id])
    }

    @Test func unknownTabIsIgnored() {
        var state = BrowserState.initial()
        let before = state
        let result = BrowserReducer.reduce(&state, .closeTab(TabID("nope")), env: env)
        #expect(!result.applied)
        #expect(state == before)
    }

    @Test func spacesKeepTheirOwnSelection() {
        var state = BrowserState.initial()
        let personalTab = open(&state, a)[0]
        let work = state.spaces[1].id
        BrowserReducer.reduce(&state, .switchSpace(work), env: env)
        #expect(state.selectedTabID == nil)
        let workTab = open(&state, b)[0]
        let result = BrowserReducer.reduce(&state, .switchSpace(state.spaces[0].id), env: env)
        #expect(state.selectedTabID == personalTab)
        #expect(result.effects == [.showTab(personalTab)])
        #expect(state.spaces[1].selectedTabID == workTab)
    }

    @Test func spaceOffsetStepsAlongTheBarAndStopsAtEachEnd() {
        var state = BrowserState.initial()
        let (first, last) = (state.spaces[0].id, state.spaces[1].id)
        BrowserReducer.reduce(&state, .switchSpace(first), env: env)

        #expect(!BrowserReducer.reduce(&state, .switchSpaceByOffset(-1), env: env).applied)
        #expect(state.activeSpaceID == first)

        #expect(BrowserReducer.reduce(&state, .switchSpaceByOffset(1), env: env).applied)
        #expect(state.activeSpaceID == last)

        #expect(!BrowserReducer.reduce(&state, .switchSpaceByOffset(1), env: env).applied)
        #expect(state.activeSpaceID == last)

        #expect(BrowserReducer.reduce(&state, .switchSpaceByOffset(-1), env: env).applied)
        #expect(state.activeSpaceID == first)
    }

    @Test func spaceOffsetShowsTheSpacesSelectedTab() {
        var state = BrowserState.initial()
        BrowserReducer.reduce(&state, .switchSpace(state.spaces[0].id), env: env)
        let tab = open(&state, a)[0]
        BrowserReducer.reduce(&state, .switchSpaceByOffset(1), env: env)
        #expect(state.selectedTabID == nil)
        let result = BrowserReducer.reduce(&state, .switchSpaceByOffset(-1), env: env)
        #expect(state.selectedTabID == tab)
        #expect(result.effects == [.showTab(tab)])
    }

    @Test func deletingSpaceDiscardsItsPages() {
        var state = BrowserState.initial()
        let work = state.spaces[1].id
        BrowserReducer.reduce(&state, .switchSpace(work), env: env)
        let id = open(&state, a)[0]
        let result = BrowserReducer.reduce(&state, .deleteSpace(work), env: env)
        #expect(state.spaces.count == 1)
        #expect(state.tabs[id] == nil)
        #expect(result.effects.contains(.discardPage(id)))
    }

    @Test func favoritesFollowTheActiveSpace() {
        var state = BrowserState.initial()
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .toggleFavorite(id), env: env)
        #expect(state.favorites == [id])
        #expect(state.activeSpace.today.isEmpty)

        let work = state.spaces[1].id
        BrowserReducer.reduce(&state, .switchSpace(work), env: env)
        BrowserReducer.reduce(&state, .selectTab(id), env: env)
        #expect(state.activeSpaceID == work)
        #expect(state.selectedTabID == id)

        // Closing a favorite unloads it but keeps it.
        let result = BrowserReducer.reduce(&state, .closeTab(id), env: env)
        #expect(state.favorites == [id])
        #expect(state.tabs[id] != nil)
        #expect(result.effects.first == .discardPage(id))
        #expect(state.selectedTabID == nil)
    }

    @Test func clearTodayKeepsSelectedAndPinned() {
        var state = BrowserState.initial()
        let ids = open(&state, a, b, c)
        BrowserReducer.reduce(&state, .togglePin(ids[0]), env: env)
        BrowserReducer.reduce(&state, .clearToday, env: env)
        #expect(state.activeSpace.pinned == [ids[0]])
        #expect(state.activeSpace.today == [ids[2]])
    }

    @Test func profilesSeparateCookieJars() {
        var state = BrowserState.initial()
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .createProfile(name: "Client"), env: env)
        let client = state.profiles[1].id
        let personal = state.spaces[0].id
        let assign = BrowserReducer.reduce(&state, .assignProfile(personal, client), env: env)
        #expect(state.profileID(forTab: id) == client)
        #expect(assign.effects == [.discardPage(id), .showTab(id)])

        let delete = BrowserReducer.reduce(&state, .deleteProfile(client), env: env)
        #expect(state.spaces[0].profileID == .standard)
        #expect(delete.effects.last == .releaseProfile(client))
        #expect(!BrowserReducer.reduce(&state, .deleteProfile(.standard), env: env).applied)
    }

    @Test func newSpaceStartsWithItsOwnProfile() {
        var state = BrowserState.initial()
        BrowserReducer.reduce(&state, .createSpace(name: "Client"), env: env)
        #expect(state.activeSpace.name == "Client")
        #expect(state.activeSpace.profileID != .standard)
        #expect(state.profile(state.activeSpace.profileID)?.name == "Client")
    }

    @Test func newSpaceCanShareAnotherSpacesLogins() {
        var state = BrowserState.initial()
        let first = state.spaces[0]
        let profiles = state.profiles.count
        BrowserReducer.reduce(&state, .createSpace(name: "Same", sharing: first.id), env: env)
        #expect(state.activeSpace.profileID == first.profileID)
        #expect(state.profiles.count == profiles)
        #expect(!BrowserReducer.reduce(&state, .createSpace(name: "Lost", sharing: SpaceID("gone")), env: env).applied)
    }

    @Test func duplicateSpaceCopiesLookAndLoginsButNotTabs() {
        var state = BrowserState.initial()
        _ = open(&state, a)
        let source = state.spaces[0]
        BrowserReducer.reduce(&state, .setSpaceIcon(source.id, "star"), env: env)
        BrowserReducer.reduce(&state, .setSpaceHue(source.id, 0.4), env: env)
        BrowserReducer.reduce(&state, .setSpaceTheme(source.id, "dusk"), env: env)
        BrowserReducer.reduce(&state, .duplicateSpace(source.id), env: env)
        let copy = state.spaces[1]
        #expect(state.activeSpaceID == copy.id)
        #expect(copy.id != source.id)
        #expect(copy.name == "\(source.name) Copy")
        #expect(copy.icon == "star")
        #expect(copy.hue == 0.4)
        #expect(copy.themeID == "dusk")
        #expect(copy.profileID == source.profileID)
        #expect(copy.allTabIDs.isEmpty)
    }

    @Test func spaceCanLeaveASharedProfile() {
        var state = BrowserState.initial()
        let first = state.spaces[0]
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .duplicateSpace(first.id), env: env)
        BrowserReducer.reduce(&state, .switchSpace(first.id), env: env)
        let result = BrowserReducer.reduce(&state, .giveSpaceOwnProfile(first.id), env: env)
        #expect(state.spaces[0].profileID != state.spaces[1].profileID)
        #expect(state.profile(state.spaces[0].profileID)?.name == first.name)
        #expect(result.effects == [.discardPage(id), .showTab(id)])
    }

    @Test func deletingASpaceKeepsItsProfile() {
        var state = BrowserState.initial()
        BrowserReducer.reduce(&state, .createSpace(name: "Client"), env: env)
        let space = state.activeSpace
        BrowserReducer.reduce(&state, .deleteSpace(space.id), env: env)
        #expect(state.profile(space.profileID) != nil)
    }

    @Test func importAddsSpacesAndSkipsDuplicates() {
        var state = BrowserState.initial()
        _ = open(&state, a)
        let data = BrowserImport(source: "Arc", spaces: [
            .init(name: "personal", pinned: [.init(url: a, title: "A"), .init(url: b, title: "B")]),
            .init(name: "Research", icon: "book", pinned: [.init(url: c, title: "C")]),
        ], favorites: [.init(url: URL(string: "https://mail.example")!, title: "Mail")])
        BrowserReducer.reduce(&state, .importBrowserData(data), env: env)
        #expect(state.favorites.count == 1)
        #expect(state.spaces[0].pinned.count == 1) // a was already open
        #expect(state.spaces.map(\.name) == ["Personal", "Work", "Research"])
        #expect(state.spaces[2].icon == "book")
    }

    @Test func pageUpdatesChangeMetadataWithoutEffects() {
        var state = BrowserState.initial()
        let id = open(&state, a)[0]
        let result = BrowserReducer.reduce(&state, .pageDidUpdate(id, PageMetadata(url: b, title: "B")), env: env)
        #expect(state.tabs[id]?.url == b)
        #expect(state.tabs[id]?.title == "B")
        #expect(result.effects.isEmpty)
    }

    @Test func archiveClosesIdleTodayTabsButNotPinnedOrSelected() {
        var state = BrowserState.initial()
        let ids = open(&state, a, b, c)
        BrowserReducer.reduce(&state, .togglePin(ids[0]), env: env)
        // Everything was last active at env.now(); archive anything idle since a later cutoff.
        BrowserReducer.reduce(&state, .archiveTabs(idleSince: Date(timeIntervalSince1970: 2_000_000)), env: env)
        #expect(state.tabs[ids[0]] != nil) // pinned
        #expect(state.tabs[ids[1]] == nil)
        #expect(state.tabs[ids[2]] != nil) // selected
    }
}

@Suite struct OmniboxTests {
    let omnibox = Omnibox()

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("localhost:3000/x", "http://localhost:3000/x"),
        ("192.168.1.2", "http://192.168.1.2"),
        ("https://a.b/c?d=1", "https://a.b/c?d=1"),
        ("about:blank", "about:blank"),
    ])
    func addresses(input: String, expected: String) {
        #expect(omnibox.interpret(input) == .address(URL(string: expected)!))
    }

    @Test func searches() {
        guard case let .search(text, url) = omnibox.interpret("how do skylights work") else {
            Issue.record("expected a search")
            return
        }
        #expect(text == "how do skylights work")
        #expect(url.absoluteString == "https://www.google.com/search?q=how%20do%20skylights%20work")
        #expect(omnibox.interpret("   ") == nil)
        if case .address = omnibox.interpret("swift") { Issue.record("a single word is a search") }
    }

    @Test func queryCharactersAreEscaped() {
        #expect(omnibox.searchURL(for: "a&b=c")?.absoluteString == "https://www.google.com/search?q=a%26b%3Dc")
    }
}

@Suite struct HibernationTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test func sleepsIdlePagesButNotProtectedOnes() {
        let policy = HibernationPolicy(idleInterval: 60, maxAwake: 10)
        let awake = [TabID("old"): now.addingTimeInterval(-120), TabID("new"): now, TabID("sel"): now.addingTimeInterval(-500)]
        let asleep = policy.pagesToSleep(awake: awake, protected: [TabID("sel")], now: now)
        #expect(asleep == [TabID("old")])
    }

    @Test func evictsLeastRecentlyUsedBeyondLimit() {
        let policy = HibernationPolicy(idleInterval: 3600, maxAwake: 2)
        let awake = (0..<4).reduce(into: [TabID: Date]()) { $0[TabID("t\($1)")] = now.addingTimeInterval(Double(-$1)) }
        let asleep = Set(policy.pagesToSleep(awake: awake, protected: [], now: now))
        #expect(asleep == [TabID("t2"), TabID("t3")])
    }
}

@Suite struct PersistenceTests {
    @Test func roundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStateStore(fileURL: dir.appending(path: "state.json"))
        var state = BrowserState.initial()
        _ = BrowserReducer.reduce(&state, .openTab(a), env: environment())
        try store.save(state)
        #expect(try store.load() == state)
    }

    @Test func decodesStateFromBeforeProfiles() throws {
        let old = #"{"version":1,"spaces":[{"id":"s","name":"Home","hue":0.5,"pinned":[],"today":["t"],"selectedTabID":"t"}],"tabs":{"t":{"id":"t","url":"https://a.example","title":"A","createdAt":0,"lastActiveAt":0}},"activeSpaceID":"s","closedTabs":[]}"#
        let state = try JSONDecoder().decode(BrowserState.self, from: Data(old.utf8))
        #expect(state.profiles.map(\.id) == [.standard])
        #expect(state.spaces[0].profileID == .standard)
        #expect(state.favorites.isEmpty)
    }

    @Test func missingFileLoadsNil() throws {
        let store = JSONFileStateStore(fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID())/state.json"))
        #expect(try store.load() == nil)
    }

    @Test @MainActor func storeSavesAfterChanges() async throws {
        let persistence = InMemoryStateStore()
        let store = BrowserStore(persistence: persistence, saveDelay: .milliseconds(10))
        store.send(.openTab(a))
        // The save runs on the main actor, which other suites (the benchmarks) can hold for
        // seconds, so wait for it rather than for a fixed time.
        let deadline = ContinuousClock.now + .seconds(10)
        while try persistence.load()?.tabs.count != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        withExtendedLifetime(store) {}
        #expect(try persistence.load()?.tabs.count == 1)
    }
}

@Suite struct JSONValueTests {
    @Test func parsesAndSerializes() throws {
        let value = try JSONValue.parse(#"{"a":[1,true,null,"x"],"b":{"c":2.5}}"#)
        #expect(value["a"]?.arrayValue?.count == 4)
        #expect(value["b"]?["c"]?.doubleValue == 2.5)
        #expect(try JSONValue.parse(value.serialized()) == value)
    }

    @Test func jsLiteralEscapes() {
        #expect(JSONValue.jsLiteral("a\"b\n</script>") .contains("\\\""))
        #expect(!JSONValue.jsLiteral("line\nbreak").contains("\n"))
    }
}

@Suite struct ImporterTests {
    @Test func readsArcSidebar() throws {
        let json = #"""
        {"sidebar":{"containers":[{"global":{}},{"topAppsContainerIDs":[{"default":true},"top"],
          "spaces":["S1",{"id":"S1","title":"Research","containerIDs":["unpinned","u1","pinned","p1"],
                          "customInfo":{"iconType":{"emoji_v2":"🔭"}}}],
          "items":["top",{"id":"top","childrenIds":["f1"],"data":{"itemContainer":{}}},
                   "f1",{"id":"f1","childrenIds":[],"data":{"tab":{"savedURL":"https://mail.example","savedTitle":"Mail"}}},
                   "p1",{"id":"p1","childrenIds":["folder","t1"],"data":{"itemContainer":{}}},
                   "folder",{"id":"folder","title":"Docs","childrenIds":["t2"],"data":{"list":{}}},
                   "t2",{"id":"t2","childrenIds":[],"data":{"tab":{"savedURL":"https://docs.example","savedTitle":"Docs"}}},
                   "t1",{"id":"t1","title":"Renamed","childrenIds":[],"data":{"tab":{"savedURL":"https://a.example","savedTitle":"A"}}},
                   "u1",{"id":"u1","childrenIds":[],"data":{"itemContainer":{}}}]}]}}
        """#
        let result = try BrowserImporters.arc(Data(json.utf8))
        #expect(result.favorites.map(\.title) == ["Mail"])
        #expect(result.spaces.count == 1)
        #expect(result.spaces[0].name == "Research")
        #expect(result.spaces[0].icon == "🔭")
        #expect(result.spaces[0].pinned.map(\.title) == ["Docs", "Renamed"])
    }

    @Test func readsChromiumBookmarks() throws {
        let json = #"{"roots":{"bookmark_bar":{"children":[{"type":"url","name":"A","url":"https://a.example"},{"type":"folder","name":"Main","children":[{"type":"url","name":"B","url":"https://b.example"},{"type":"url","name":"","url":"https://c.example/x"}]},{"type":"folder","name":"Empty","children":[]}]},"other":{"children":[{"type":"url","name":"O","url":"https://o.example"},{"type":"url","name":"Local","url":"file:///etc/hosts"}]}}}"#
        let result = try BrowserImporters.chromium(Data(json.utf8), browser: "Aside")
        #expect(result.source == "Aside")
        #expect(result.favorites.map(\.title) == ["A"])
        #expect(result.spaces.map(\.name) == ["Main", "Aside"])
        #expect(result.spaces[0].pinned.map(\.title) == ["B", "c.example"])
        #expect(result.spaces[1].pinned.map(\.title) == ["O"])
    }

    @Test func pinnedTabsUnloadOnClose() {
        var state = BrowserState.initial()
        let id = BrowserReducer.reduce(&state, .openTab(URL(string: "https://a.example")!), env: environment()).openedTabID!
        BrowserReducer.reduce(&state, .togglePin(id), env: environment())
        let result = BrowserReducer.reduce(&state, .closeTab(id), env: environment())
        #expect(state.activeSpace.pinned == [id])
        #expect(result.effects == [.discardPage(id), .showTab(nil)])
        BrowserReducer.reduce(&state, .removeTab(id), env: environment())
        #expect(state.tabs[id] == nil)
    }
}
