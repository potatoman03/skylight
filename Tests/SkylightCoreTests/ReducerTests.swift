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

    /// A new Space on a new profile.
    @discardableResult
    func separateSpace(_ state: inout BrowserState, _ name: String) -> ProfileID {
        BrowserReducer.reduce(&state, .createProfile(name: name), env: env)
        let profile = state.profiles.last!.id
        BrowserReducer.reduce(&state, .createSpace(name: name, profile: profile), env: env)
        return profile
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

    @Test func favoritesBelongToTheirSpace() {
        var state = BrowserState.initial()
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .toggleFavorite(id), env: env)
        #expect(state.favorites == [id])
        #expect(state.activeSpace.today.isEmpty)
        let personal = state.activeSpaceID

        BrowserReducer.reduce(&state, .switchSpace(state.spaces[1].id), env: env)
        #expect(state.favorites.isEmpty)
        #expect(state.isFavorite(id))

        // Opening one from elsewhere goes back to its Space.
        BrowserReducer.reduce(&state, .selectTab(id), env: env)
        #expect(state.activeSpaceID == personal)
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

    @Test func newSpaceSharesTheActiveSpacesProfile() {
        var state = BrowserState.initial()
        let client = separateSpace(&state, "Client")
        let profiles = state.profiles.count
        BrowserReducer.reduce(&state, .createSpace(name: "More"), env: env)
        #expect(state.activeSpace.name == "More")
        #expect(state.activeSpace.profileID == client)
        #expect(state.profiles.count == profiles)
    }

    @Test func newSpaceCanUseAnotherProfile() {
        var state = BrowserState.initial()
        let client = separateSpace(&state, "Client")
        #expect(state.activeSpace.name == "Client")
        #expect(state.activeSpace.profileID == client)
        #expect(!BrowserReducer.reduce(&state, .createSpace(name: "Lost", profile: ProfileID("gone")), env: env).applied)
    }

    @Test func aProfileCanUseAnothersPasswords() {
        var state = BrowserState.initial()
        let spaces = state.spaces.count
        BrowserReducer.reduce(&state, .createProfile(name: "Own"), env: env)
        let own = state.profiles.last!.id
        BrowserReducer.reduce(&state, .createProfile(name: "Linked", passwordsFrom: own), env: env)
        let linked = state.profiles.last!.id
        #expect(state.spaces.count == spaces)
        #expect(state.passwordProfile(for: own) == own)
        #expect(state.passwordProfile(for: linked) == own)
    }

    @Test func passwordsLinkToTheProfileThatHoldsThem() {
        var state = BrowserState.initial()
        BrowserReducer.reduce(&state, .createProfile(name: "One", passwordsFrom: .standard), env: env)
        let one = state.profiles.last!.id
        BrowserReducer.reduce(&state, .createProfile(name: "Two", passwordsFrom: one), env: env)
        #expect(state.profiles.last!.passwordsFrom == .standard)
    }

    @Test func deletingAProfileMovesItsPasswordLinksToDefault() {
        var state = BrowserState.initial()
        BrowserReducer.reduce(&state, .createProfile(name: "Own"), env: env)
        let own = state.profiles.last!.id
        BrowserReducer.reduce(&state, .createProfile(name: "Linked", passwordsFrom: own), env: env)
        let linked = state.profiles.last!.id
        BrowserReducer.reduce(&state, .deleteProfile(own), env: env)
        #expect(state.passwordProfile(for: linked) == .standard)
    }

    @Test func oldProfilesKeepTheirOwnPasswords() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"p","name":"Old"}"#.utf8))
        #expect(profile.passwordsFrom == nil)
    }

    @Test func spaceSetupRemembersWhatItCanRead() throws {
        let setup = try JSONDecoder().decode(SpaceSetup.self, from: Data(#"{"sharesEverything":false,"sites":["github","gitlab"]}"#.utf8))
        #expect(setup == SpaceSetup(sharesEverything: false, sites: [.github]))
        let blank = try JSONDecoder().decode(SpaceSetup.self, from: Data("{}".utf8))
        #expect(blank == SpaceSetup())
        #expect(try JSONDecoder().decode(SpaceSetup.self, from: JSONEncoder().encode(setup)) == setup)
    }

    @Test func signInSitesCoverTheirAccountDomains() {
        #expect(SignInSite.google.domains.contains("youtube.com"))
        #expect(SignInSite.github.domains == ["github.com"])
    }

    @Test func aFavoriteOpensInItsSpacesProfile() {
        var state = BrowserState.initial()
        BrowserReducer.reduce(&state, .createProfile(name: "Work", passwordsFrom: nil), env: env)
        let work = state.spaces[1].id
        let profile = state.profiles[1].id
        BrowserReducer.reduce(&state, .assignProfile(work, profile), env: env)
        BrowserReducer.reduce(&state, .switchSpace(work), env: env)
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .toggleFavorite(id), env: env)
        BrowserReducer.reduce(&state, .switchSpace(state.spaces[0].id), env: env)
        #expect(state.profileID(forTab: id) == profile)
    }

    @Test func movingAFavoriteToAnotherSpaceLeavesOneTab() {
        var state = BrowserState.initial()
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .toggleFavorite(id), env: env)
        let work = state.spaces[1]
        BrowserReducer.reduce(&state, .moveTabToSpace(id, work.id), env: env)
        #expect(state.spaces[0].favorites.isEmpty)
        #expect(state.spaces[0].today.isEmpty)
        #expect(state.activeSpace.today == [id])
        #expect(state.tabs[id] != nil)
    }

    @Test func deletingASpaceTakesItsFavorites() {
        var state = BrowserState.initial()
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .toggleFavorite(id), env: env)
        let result = BrowserReducer.reduce(&state, .deleteSpace(state.activeSpaceID), env: env)
        #expect(state.tabs[id] == nil)
        #expect(result.effects.contains(.discardPage(id)))
    }

    @Test func closingATabDoesNotFallToAFavorite() {
        var state = BrowserState.initial()
        let ids = open(&state, a, b)
        BrowserReducer.reduce(&state, .toggleFavorite(ids[0]), env: env)
        BrowserReducer.reduce(&state, .selectTab(ids[1]), env: env)
        BrowserReducer.reduce(&state, .closeTab(ids[1]), env: env)
        #expect(state.selectedTabID == nil)
    }

    @Test func duplicateSpaceCopiesLookAndLoginsButNotTabs() {
        var state = BrowserState.initial()
        _ = open(&state, a)
        let source = state.spaces[0]
        BrowserReducer.reduce(&state, .setSpaceIcon(source.id, "star"), env: env)
        BrowserReducer.reduce(&state, .setSpaceHue(source.id, 0.4), env: env)
        BrowserReducer.reduce(&state, .setSpaceTheme(source.id, "dusk"), env: env)
        state.spaces[0].tint = .strong
        BrowserReducer.reduce(&state, .duplicateSpace(source.id), env: env)
        let copy = state.spaces[1]
        #expect(state.activeSpaceID == copy.id)
        #expect(copy.id != source.id)
        #expect(copy.name == "\(source.name) Copy")
        #expect(copy.icon == "star")
        #expect(copy.hue == 0.4)
        #expect(copy.themeID == "dusk")
        #expect(copy.tint == .strong)
        #expect(copy.profileID == source.profileID)
        #expect(copy.allTabIDs.isEmpty)
    }

    @Test func spaceCanLeaveASharedProfile() {
        var state = BrowserState.initial()
        let first = state.spaces[0]
        let id = open(&state, a)[0]
        BrowserReducer.reduce(&state, .duplicateSpace(first.id), env: env)
        BrowserReducer.reduce(&state, .switchSpace(first.id), env: env)
        BrowserReducer.reduce(&state, .createProfile(name: first.name), env: env)
        let result = BrowserReducer.reduce(&state, .assignProfile(first.id, state.profiles.last!.id), env: env)
        #expect(state.spaces[0].profileID != state.spaces[1].profileID)
        #expect(result.effects == [.discardPage(id), .showTab(id)])
    }

    @Test func deletingASpaceKeepsItsProfile() {
        var state = BrowserState.initial()
        separateSpace(&state, "Client")
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

    @Test func arcProfilesBecomeProfiles() {
        var state = BrowserState.initial()
        let shared = BrowserImport.Link(url: a, title: "A")
        var data = BrowserImport(source: "Arc", spaces: [
            .init(name: "Client", pinned: [shared], sourceProfile: "Profile 2"),
            .init(name: "Client Docs", pinned: [.init(url: b, title: "B")], sourceProfile: "Profile 2"),
            .init(name: "Side", pinned: [shared]),
            .init(name: "Bare", pinned: [], sourceProfile: "Profile 3"),
        ], favorites: [])
        data.spaces[0].favorites = [.init(url: c, title: "C")]
        data.profileNames = ["Profile 2": "Acme"]
        BrowserReducer.reduce(&state, .importBrowserData(data), env: env)

        let acme = state.profiles.first { $0.name == "Acme" }?.id
        #expect(acme != nil)
        #expect(state.profiles.contains { $0.name == "Profile 3" })
        let client = state.spaces.first { $0.name == "Client" }
        #expect(client?.profileID == acme)
        #expect(client?.favorites.count == 1)
        #expect(state.spaces.first { $0.name == "Client Docs" }?.profileID == acme)
        // The same page in another profile is a different tab.
        let side = state.spaces.first { $0.name == "Side" }
        #expect(side?.profileID == .standard)
        #expect(side?.pinned.count == 1)
        // A profile with nothing pinned still gets a Space to hold its logins.
        #expect(state.spaces.contains { $0.name == "Bare" })

        let (tabs, profiles, spaces) = (state.tabs.count, state.profiles.count, state.spaces.count)
        BrowserReducer.reduce(&state, .importBrowserData(data), env: env)
        #expect(state.tabs.count == tabs)
        #expect(state.profiles.count == profiles)
        #expect(state.spaces.count == spaces)
    }

    @Test func aSpaceImportedEarlierMovesToItsArcProfile() {
        var state = BrowserState.initial()
        let links = [BrowserImport.Link(url: a, title: "A")]
        BrowserReducer.reduce(&state, .importBrowserData(.init(source: "Arc", spaces: [.init(name: "Client", pinned: links)], favorites: [])), env: env)
        #expect(state.spaces.first { $0.name == "Client" }?.profileID == .standard)
        let tabs = state.tabs.count

        var data = BrowserImport(source: "Arc", spaces: [.init(name: "Client", pinned: links, sourceProfile: "Profile 2")], favorites: [])
        data.profileNames = ["Profile 2": "Acme"]
        let result = BrowserReducer.reduce(&state, .importBrowserData(data), env: env)
        let client = state.spaces.first { $0.name == "Client" }
        #expect(client?.profileID == state.profiles.first { $0.name == "Acme" }?.id)
        #expect(state.tabs.count == tabs)
        #expect(result.effects.contains(.discardPage(client!.pinned[0])))
    }

    @Test func aSpaceOnAnotherProfileStaysPut() {
        var state = BrowserState.initial()
        BrowserReducer.reduce(&state, .createProfile(name: "Mine"), env: env)
        let mine = state.profiles.first { $0.name == "Mine" }!.id
        let work = state.spaces[1].id
        BrowserReducer.reduce(&state, .assignProfile(work, mine), env: env)
        let data = BrowserImport(source: "Arc", spaces: [.init(name: "Work", pinned: [.init(url: a, title: "A")], sourceProfile: "Profile 2")], favorites: [])
        BrowserReducer.reduce(&state, .importBrowserData(data), env: env)
        #expect(state.spaces.first { $0.id == work }?.profileID == mine)
        #expect(state.spaces.first { $0.id == work }?.pinned.count == 1)
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

    @Test func shortAddressesLeadBack() {
        func short(_ url: String) -> String { omnibox.short(URL(string: url)!) }
        #expect(short("https://onorca.dev/") == "onorca.dev")
        #expect(short("https://growth.example.com/dropoffs") == "growth.example.com/dropoffs")
        #expect(short("https://example.com/a/") == "example.com/a/")
        #expect(short("https://example.com/?q=1") == "example.com/?q=1")
        #expect(short("http://127.0.0.1:55037/") == "127.0.0.1:55037")
        // Typed short, these would go somewhere else.
        #expect(short("http://example.com/") == "http://example.com/")
        #expect(short("https://localhost/") == "https://localhost/")
        #expect(short("https://intranet/") == "https://intranet/")
        #expect(short("about:blank") == "about:blank")
    }

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

    @Test(arguments: ["file:///etc/passwd", "FILE:///etc/passwd", "chrome://settings", "about:blank", "data:text/html,x",
                      "view-source:https://a.b", "skylight://x"])
    func addressesAgentsCantOpen(input: String) {
        #expect(omnibox.interpret(input)?.isWeb != true)
    }

    @Test(arguments: ["example.com", "HTTPS://a.b", "how do skylights work"])
    func addressesAgentsCanOpen(input: String) {
        #expect(omnibox.interpret(input)?.isWeb == true)
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

    @Test func keepsMorePagesOnBiggerMacs() {
        let gigabyte: UInt64 = 1 << 30
        #expect(HibernationPolicy(memoryBytes: 4 * gigabyte).maxAwake == 8)
        #expect(HibernationPolicy(memoryBytes: 16 * gigabyte).maxAwake == 16)
        #expect(HibernationPolicy(memoryBytes: 128 * gigabyte).maxAwake == 24)
    }

    @Test func aPinnedSetOfTabsStaysUpBetweenVisits() {
        // Seven tabs, the last seen ten minutes ago: none should have to load again.
        let awake = (0..<7).reduce(into: [TabID: Date]()) { $0[TabID("t\($1)")] = now.addingTimeInterval(Double($1) * -100) }
        #expect(HibernationPolicy(memoryBytes: 8 << 30).pagesToSleep(awake: awake, protected: [], now: now).isEmpty)
    }

    @Test func givesBackTheOlderHalfWhenMemoryRunsShort() {
        let awake = (0..<4).reduce(into: [TabID: Date]()) { $0[TabID("t\($1)")] = now.addingTimeInterval(Double($1) * 60) }
        let shed = HibernationPolicy().pagesToShed(awake: awake, protected: [TabID("t0")])
        #expect(shed == [TabID("t1"), TabID("t2")])
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

    @Test func sharedFavoritesLandInTheActiveSpace() throws {
        let old = #"{"version":1,"spaces":[{"id":"s","name":"Home","hue":0.5},{"id":"w","name":"Work","hue":0.1,"selectedTabID":"t"}],"favorites":["t"],"tabs":{"t":{"id":"t","url":"https://a.example","title":"A","createdAt":0,"lastActiveAt":0}},"activeSpaceID":"s"}"#
        var state = try JSONDecoder().decode(BrowserState.self, from: Data(old.utf8))
        state.normalize()
        #expect(state.spaces[0].favorites == [TabID("t")])
        #expect(state.spaces[1].favorites.isEmpty)
        #expect(state.spaces[1].selectedTabID == nil)
        #expect(state.tabs[TabID("t")] != nil)
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

    // Current Arc writes `newContainerIDs` with objects for markers, and may leave out `containerIDs`.
    @Test func foldersKeepTheirColorWhenImported() {
        var state = BrowserState.initial()
        let links = [BrowserImport.Link(url: URL(string: "https://a.example")!, title: "A")]
        let data = BrowserImport(source: "Aside", spaces: [], favorites: [], folders: [.init(name: "Work", links: links, color: .green)])
        _ = BrowserReducer.reduce(&state, .importBrowserData(data), env: ReducerEnvironment())
        #expect(state.activeSpace.folders.first?.color == .green)
    }

    @Test func aFolderCanChangeItsColor() {
        var state = BrowserState.initial()
        let env = ReducerEnvironment()
        _ = BrowserReducer.reduce(&state, .createFolder(id: "f", space: state.activeSpaceID, name: "Work"), env: env)
        _ = BrowserReducer.reduce(&state, .setFolderColor("f", .pink), env: env)
        #expect(state.activeSpace.folders[0].color == .pink)
        _ = BrowserReducer.reduce(&state, .setFolderColor("f", nil), env: env)
        #expect(state.activeSpace.folders[0].color == nil)
    }

    @Test func aFolderSavedWithoutAColorStillLoads() throws {
        let saved = #"{"id":"f","name":"Work","tabs":[],"isOpen":true}"#
        let folder = try JSONDecoder().decode(TabFolder.self, from: Data(saved.utf8))
        #expect(folder.color == nil)
    }

    @Test func aSpaceTurnsIntoAFolderWithoutLosingATab() {
        var state = BrowserState.initial()
        let env = ReducerEnvironment()
        let keep = state.activeSpaceID
        _ = BrowserReducer.reduce(&state, .createSpace(name: "Email"), env: env)
        let email = state.activeSpaceID
        #expect(email != keep)
        _ = BrowserReducer.reduce(&state, .openTab(URL(string: "https://mail.example")!), env: env)
        let tabs = state.activeSpace.allTabIDs
        #expect(!tabs.isEmpty)

        _ = BrowserReducer.reduce(&state, .turnSpaceIntoFolder(email, in: keep), env: env)
        #expect(state.activeSpaceID == keep)
        #expect(!state.spaces.contains { $0.id == email })
        let folder = state.activeSpace.folders.first { $0.name == "Email" }
        #expect(folder?.tabs == tabs)
        #expect(Set(tabs).isSubset(of: Set(state.activeSpace.pinned)))
        #expect(tabs.allSatisfy { state.tabs[$0] != nil })
    }

    @Test func aSpaceOnlyTurnsIntoAFolderInItsOwnProfile() {
        var state = BrowserState.initial()
        let env = ReducerEnvironment()
        let keep = state.activeSpaceID
        _ = BrowserReducer.reduce(&state, .createProfile(name: "Work"), env: env)
        let profile = state.profiles.last!.id
        #expect(profile != state.activeSpace.profileID)
        _ = BrowserReducer.reduce(&state, .createSpace(name: "Work", profile: profile), env: env)
        let work = state.activeSpaceID
        #expect(state.activeSpace.profileID == profile)
        _ = BrowserReducer.reduce(&state, .openTab(URL(string: "https://mail.example")!), env: env)
        let before = state
        let result = BrowserReducer.reduce(&state, .turnSpaceIntoFolder(work, in: keep), env: env)
        #expect(!result.applied)
        #expect(state == before)
    }

    @Test func aRedSpaceKeepsItsColorAsAFolder() {
        var state = BrowserState.initial()
        let env = ReducerEnvironment()
        let keep = state.activeSpaceID
        _ = BrowserReducer.reduce(&state, .createSpace(name: "Red", hue: 0), env: env)
        let red = state.activeSpaceID
        _ = BrowserReducer.reduce(&state, .openTab(URL(string: "https://red.example")!), env: env)
        _ = BrowserReducer.reduce(&state, .turnSpaceIntoFolder(red, in: keep), env: env)
        #expect(state.activeSpace.folders.first { $0.name == "Red" }?.color == .red)
    }

    @Test func foldersGoInTheSpaceOnScreenWithoutMakingSpaces() {
        var state = BrowserState.initial()
        let spaces = state.spaces.count
        let link = BrowserImport.Link(url: URL(string: "https://one.example/")!, title: "One")
        let more = BrowserImport.Link(url: URL(string: "https://two.example/")!, title: "Two")
        let data = BrowserImport(source: "Aside", spaces: [], favorites: [], folders: [.init(name: "Email", links: [link])])
        BrowserReducer.reduce(&state, .importBrowserData(data), env: environment())
        #expect(state.spaces.count == spaces)
        #expect(state.activeSpace.folders.map(\.name) == ["Email"])
        #expect(state.activeSpace.pinned.count == 1)
        #expect(state.activeSpace.folders[0].tabs == state.activeSpace.pinned)

        let again = BrowserImport(source: "Aside", spaces: [], favorites: [], folders: [.init(name: "email", links: [link, more])])
        BrowserReducer.reduce(&state, .importBrowserData(again), env: environment())
        #expect(state.activeSpace.folders.count == 1)
        #expect(state.activeSpace.folders[0].tabs.count == 2)
    }

    @Test func readsArcsNewerContainers() throws {
        let json = #"""
        {"sidebar":{"containers":[{"global":{}},{"topAppsContainerIDs":[],
          "spaces":["S1",{"id":"S1","title":"New","newContainerIDs":[{"unpinned":{"_0":{"shared":{}}}},"u1",{"pinned":{}},"p1"]},
                    "S2",{"id":"S2","title":"Both","containerIDs":["pinned","gone"],"newContainerIDs":[{"pinned":{}},"p2"]},
                    "S3",{"id":"S3","title":"Old","legacyContainerIDs":["pinned","p3"]}],
          "items":["p1",{"id":"p1","childrenIds":["t1"],"data":{"itemContainer":{}}},
                   "t1",{"id":"t1","childrenIds":[],"data":{"tab":{"savedURL":"https://one.example","savedTitle":"One"}}},
                   "p2",{"id":"p2","data":{"itemContainer":{}}},
                   "t2",{"id":"t2","parentID":"p2","data":{"tab":{"savedURL":"https://two.example","savedTitle":"Two"}}},
                   "p3",{"id":"p3","childrenIds":["t3"],"data":{"itemContainer":{}}},
                   "t3",{"id":"t3","childrenIds":[],"data":{"tab":{"savedURL":"https://three.example","savedTitle":"Three"}}},
                   "u1",{"id":"u1","childrenIds":[],"data":{"itemContainer":{}}}]}]}}
        """#
        let result = try BrowserImporters.arc(Data(json.utf8))
        #expect(result.spaces.map(\.name) == ["New", "Both", "Old"])
        #expect(result.spaces.map { $0.pinned.map(\.title) } == [["One"], ["Two"], ["Three"]])
    }

    @Test func readsArcProfiles() throws {
        let json = #"""
        {"sidebar":{"containers":[{"global":{}},{"topAppsContainerIDs":[{"default":true},"top",{"custom":{"_0":{"directoryBasename":"Profile 2","machineID":"m"}}},"top2"],
          "spaces":["S1",{"id":"S1","title":"Home","containerIDs":["pinned","p1"],"profile":{"default":true}},
                    "S2",{"id":"S2","title":"Client","containerIDs":["pinned","p2"],"profile":{"custom":{"_0":{"directoryBasename":"Profile 2","machineID":"m"}}}},
                    "S3",{"id":"S3","title":"Odd","containerIDs":["pinned","p3"],"profile":{"custom":{"_0":{"directoryBasename":"../secrets"}}}}],
          "items":["top",{"id":"top","childrenIds":["f1"],"data":{"itemContainer":{}}},
                   "top2",{"id":"top2","childrenIds":["f2"],"data":{"itemContainer":{}}},
                   "f1",{"id":"f1","childrenIds":[],"data":{"tab":{"savedURL":"https://mail.example","savedTitle":"Mail"}}},
                   "f2",{"id":"f2","childrenIds":[],"data":{"tab":{"savedURL":"https://client.example","savedTitle":"Client Mail"}}},
                   "p1",{"id":"p1","childrenIds":[],"data":{"itemContainer":{}}},
                   "p2",{"id":"p2","childrenIds":[],"data":{"itemContainer":{}}},
                   "p3",{"id":"p3","childrenIds":[],"data":{"itemContainer":{}}}]}]}}
        """#
        let result = try BrowserImporters.arc(Data(json.utf8))
        #expect(result.spaces.map(\.sourceProfile) == [nil, "Profile 2", nil])
        #expect(result.favorites.map(\.title) == ["Mail"])
        #expect(result.spaces[1].favorites.map(\.title) == ["Client Mail"])
        #expect(result.profileFolders == ["Profile 2"])
    }

    @Test func readsChromiumProfileNames() {
        let json = #"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 2":{"name":"Acme"},"Profile 3":{}}}}"#
        let names = BrowserImporters.chromiumProfileNames(Data(json.utf8))
        #expect(names == ["Default": "Personal", "Profile 2": "Acme"])
        #expect(BrowserImporters.chromiumProfileNames(Data("nope".utf8)).isEmpty)
        var data = BrowserImport(source: "Arc", spaces: [], favorites: [])
        data.profileNames = names
        #expect(data.profileName(for: "Profile 2") == "Acme")
        #expect(data.profileName(for: "Profile 3") == "Profile 3")
    }

    @Test func readsChromiumBookmarks() throws {
        let json = #"{"roots":{"bookmark_bar":{"children":[{"type":"url","name":"A","url":"https://a.example"},{"type":"folder","name":"Main","children":[{"type":"url","name":"B","url":"https://b.example"},{"type":"url","name":"","url":"https://c.example/x"}]},{"type":"folder","name":"Empty","children":[]}]},"other":{"children":[{"type":"url","name":"O","url":"https://o.example"},{"type":"url","name":"Local","url":"file:///etc/hosts"}]}}}"#
        let result = try BrowserImporters.chromium(Data(json.utf8), browser: "Aside")
        #expect(result.source == "Aside")
        #expect(result.favorites.map(\.title) == ["A"])
        #expect(result.spaces.isEmpty)
        #expect(result.folders.map(\.name) == ["Main", "Bookmarks"])
        #expect(result.folders[0].links.map(\.title) == ["B", "c.example"])
        #expect(result.folders[1].links.map(\.title) == ["O"])
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
