import Foundation
import Testing
@testable import SkylightCore

/// Timings for the paths every click goes through. Bounds are loose (debug builds, busy machines);
/// the printed numbers are the point. Run: swift test -c release --filter Performance
@Suite struct PerformanceTests {
    private func time(_ label: String, count: Int, _ body: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock()
        let elapsed = try clock.measure(body)
        let each = elapsed / count
        print("BENCH \(label): \(elapsed) total, \(each) each (n=\(count))")
        return elapsed
    }

    private func bigState(tabs: Int) -> BrowserState {
        var state = BrowserState.initial()
        let env = ReducerEnvironment()
        for i in 0..<tabs {
            BrowserReducer.reduce(&state, .openTab(URL(string: "https://site\(i).example/path?q=\(i)")!, select: i % 10 == 0), env: env)
        }
        return state
    }

    @Test func reducerThroughput() {
        var state = BrowserState.initial()
        let env = ReducerEnvironment()
        var ids: [TabID] = []
        let open = time("reduce openTab", count: 5_000) {
            for i in 0..<5_000 { ids.append(BrowserReducer.reduce(&state, .openTab(URL(string: "https://e\(i).example")!), env: env).openedTabID!) }
        }
        let select = time("reduce selectTab", count: 5_000) {
            for id in ids { BrowserReducer.reduce(&state, .selectTab(id), env: env) }
        }
        let close = time("reduce closeTab", count: 5_000) {
            for id in ids { BrowserReducer.reduce(&state, .closeTab(id), env: env) }
        }
        #expect(open < .seconds(10) && select < .seconds(10) && close < .seconds(10))
    }

    @Test func savingAndLoadingState() throws {
        let state = bigState(tabs: 2_000)
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStateStore(fileURL: dir.appending(path: "state.json"))
        let save = try time("save 2,000 tabs", count: 1) { try store.save(state) }
        var loaded: BrowserState?
        let load = try time("load 2,000 tabs", count: 1) { loaded = try store.load() }
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: "state.json").path)[.size] as? Int) ?? 0
        print("BENCH state.json with 2,000 tabs: \(size / 1024) KB")
        // Saved dates keep milliseconds.
        let loadedState = try #require(loaded)
        #expect(loadedState.spaces == state.spaces && loadedState.tabs.keys == state.tabs.keys)
        let drift = state.tabs.values.map { abs($0.lastActiveAt.timeIntervalSince(loadedState.tabs[$0.id]!.lastActiveAt)) }.max() ?? 0
        #expect(drift < 0.001)
        #expect(save < .seconds(2) && load < .seconds(2))
    }

    @Test func importingFromArc() throws {
        let tabs = (0..<500).map { #"{"id":"t\#($0)","childrenIds":[],"data":{"tab":{"savedURL":"https://s\#($0).example","savedTitle":"S\#($0)"}}}"# }
        let items = (0..<500).map { #""t\#($0)","# + tabs[$0] }.joined(separator: ",")
        let children = (0..<500).map { #""t\#($0)""# }.joined(separator: ",")
        let json = #"{"sidebar":{"containers":[{"global":{}},{"topAppsContainerIDs":[],"spaces":["S",{"id":"S","title":"Big","containerIDs":["unpinned","u","pinned","p"]}],"items":["p",{"id":"p","childrenIds":[\#(children)],"data":{"itemContainer":{}}},\#(items)]}]}}"#
        var result: BrowserImport?
        let parse = try time("parse Arc sidebar, 500 pinned", count: 1) { result = try BrowserImporters.arc(Data(json.utf8)) }
        var state = BrowserState.initial()
        let apply = time("import 500 tabs", count: 1) { BrowserReducer.reduce(&state, .importBrowserData(result!), env: ReducerEnvironment()) }
        #expect(state.spaces.last?.pinned.count == 500)
        #expect(parse < .seconds(2) && apply < .seconds(2))
    }
}
