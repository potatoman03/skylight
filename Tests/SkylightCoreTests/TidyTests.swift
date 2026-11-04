import Foundation
import Testing
@testable import SkylightCore

@Suite struct TidyTests {
    let env = ReducerEnvironment(now: { Date(timeIntervalSince1970: 1_000_000) })

    func tabs(_ urls: [String]) -> [Tab] {
        var state = BrowserState.initial()
        return urls.map { url in
            let id = BrowserReducer.reduce(&state, .openTab(URL(string: url)!, placement: .end), env: env).openedTabID!
            return state.tabs[id]!
        }
    }

    @Test func groupsTwoOrMoreTabsBySite() {
        let tabs = tabs(["https://github.com/a", "https://news.ycombinator.com", "https://gist.github.com/b", "https://www.bbc.co.uk/news", "https://bbc.co.uk/sport"])
        let groups = Tidy.bySite(tabs)
        #expect(groups == [TidyGroup(name: "Github", tabs: [tabs[0].id, tabs[2].id]), TidyGroup(name: "Bbc", tabs: [tabs[3].id, tabs[4].id])])
    }

    @Test func cleaningDropsUnknownRepeatedAndLoneTabs() {
        let ids = (0..<4).map { TabID("t\($0)") }
        let groups = Tidy.clean([
            TidyGroup(name: " Reading. ", tabs: [ids[0], ids[1], TabID("other")]),
            TidyGroup(name: "Again", tabs: [ids[1], ids[2]]),
            TidyGroup(name: "", tabs: [ids[2], ids[3]]),
        ], allowed: ids)
        #expect(groups == [TidyGroup(name: "Reading", tabs: [ids[0], ids[1]])])
    }

    @Test func leavesSplitTabsAlone() {
        var state = BrowserState.initial()
        let ids = (0..<3).map { i in BrowserReducer.reduce(&state, .openTab(URL(string: "https://\(i).example")!, placement: .end), env: env).openedTabID! }
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        #expect(Tidy.candidates(state.activeSpace) == [ids[2]])
    }
}
