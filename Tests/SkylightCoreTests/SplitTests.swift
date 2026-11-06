import CoreGraphics
import Foundation
import Testing
@testable import SkylightCore

@Suite struct SplitTests {
    let env = ReducerEnvironment(now: { Date(timeIntervalSince1970: 1_000_000) })

    func state(tabs count: Int) -> (BrowserState, [TabID]) {
        var state = BrowserState.initial()
        let ids = (0..<count).map { i in
            BrowserReducer.reduce(&state, .openTab(URL(string: "https://\(i).example")!, placement: .end), env: env).openedTabID!
        }
        return (state, ids)
    }

    @Test func splittingMakesOneSplitAndFocusesTheNewPane() {
        var (state, ids) = state(tabs: 3)
        let result = BrowserReducer.reduce(&state, .splitTab(ids[2], beside: ids[0], edge: .trailing), env: env)
        let split = try! #require(state.activeSpace.splits.first)
        #expect(split.tabs == [ids[0], ids[2]])
        #expect(split.axis == .horizontal)
        #expect(split.fractions == [0.5, 0.5])
        #expect(state.selectedTabID == ids[2])
        #expect(state.visibleTabIDs == [ids[0], ids[2]])
        // The new pane moves next to its partner in the sidebar.
        #expect(state.activeSpace.today == [ids[0], ids[2], ids[1]])
        #expect(result.effects == [.showTab(ids[2])])
    }

    /// What a pane's × in the sidebar does.
    func closePane(_ id: TabID, _ state: inout BrowserState) {
        BrowserReducer.reduce(&state, .leaveSplit(id), env: env)
        BrowserReducer.reduce(&state, .closeTab(id), env: env)
    }

    @Test func closingAPaneClosesItsTabAndEndsATwoPaneSplit() {
        var (state, ids) = state(tabs: 2)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        closePane(ids[1], &state)
        #expect(state.tabs[ids[1]] == nil)
        #expect(state.tabs[ids[0]] != nil)
        #expect(state.activeSpace.splits.isEmpty)
    }

    @Test func closingAPinnedPaneLeavesNoSleepingPane() {
        var (state, ids) = state(tabs: 3)
        BrowserReducer.reduce(&state, .togglePin(ids[0]), env: env)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .splitTab(ids[2], beside: ids[1], edge: .trailing), env: env)
        closePane(ids[0], &state)
        #expect(state.tabs[ids[0]] != nil)
        #expect(state.activeSpace.split(containing: ids[0]) == nil)
        #expect(state.activeSpace.split(containing: ids[1])?.tabs == [ids[1], ids[2]])
    }

    @Test func addingAPaneTakesHalfOfItsNeighbor() {
        var (state, ids) = state(tabs: 3)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .splitTab(ids[2], beside: ids[1], edge: .leading), env: env)
        let split = state.activeSpace.splits[0]
        #expect(split.tabs == [ids[0], ids[2], ids[1]])
        #expect(split.fractions == [0.5, 0.25, 0.25])
    }

    @Test func aSplitOnlyGrowsAlongItsAxisAndUpToFourPanes() {
        var (state, ids) = state(tabs: 6)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        #expect(!BrowserReducer.reduce(&state, .splitTab(ids[2], beside: ids[0], edge: .bottom), env: env).applied)
        BrowserReducer.reduce(&state, .splitTab(ids[2], beside: ids[1], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .splitTab(ids[3], beside: ids[2], edge: .trailing), env: env)
        #expect(!BrowserReducer.reduce(&state, .splitTab(ids[4], beside: ids[3], edge: .trailing), env: env).applied)
        #expect(state.activeSpace.splits[0].tabs.count == 4)
    }

    @Test func closingAPaneKeepsFocusInTheSplit() {
        var (state, ids) = state(tabs: 4)
        BrowserReducer.reduce(&state, .splitTab(ids[3], beside: ids[1], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .closeTab(ids[3]), env: env)
        #expect(state.selectedTabID == ids[1])
        // One pane left: no split.
        #expect(state.activeSpace.splits.isEmpty)
    }

    @Test func movingASplitMovesAllItsTabs() {
        var (state, ids) = state(tabs: 4)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .moveTab(ids[0], to: .today, index: 2), env: env)
        #expect(state.activeSpace.today == [ids[2], ids[3], ids[0], ids[1]])
        BrowserReducer.reduce(&state, .moveTab(ids[1], to: .pinned, index: 0), env: env)
        #expect(state.activeSpace.pinned == [ids[0], ids[1]])
        #expect(state.activeSpace.splits.count == 1)
    }

    @Test func pinningOrFavoritingAPaneTakesItOut() {
        var (state, ids) = state(tabs: 3)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .togglePin(ids[1]), env: env)
        #expect(state.activeSpace.splits.isEmpty)
        BrowserReducer.reduce(&state, .splitTab(ids[2], beside: ids[0], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .moveToFavorites(ids[2], index: 0), env: env)
        #expect(state.activeSpace.splits.isEmpty)
        #expect(state.favorites == [ids[2]])
    }

    @Test func resizingKeepsPanesWithinLimits() {
        var split = TabSplit(tabs: [TabID("a"), TabID("b")])
        split.moveDivider(after: 0, by: 0.9)
        #expect(abs(split.fractions[1] - TabSplit.minFraction) < 1e-9)
        #expect(abs(split.fractions.reduce(0, +) - 1) < 1e-9)
        var (state, ids) = state(tabs: 2)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .resizeSplit(ids[0], fractions: [3, 1]), env: env)
        #expect(state.activeSpace.splits[0].fractions == [0.75, 0.25])
    }

    @Test func rotatingAndReorderingPanes() {
        var (state, ids) = state(tabs: 3)
        BrowserReducer.reduce(&state, .splitTab(ids[1], beside: ids[0], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .splitTab(ids[2], beside: ids[1], edge: .trailing), env: env)
        BrowserReducer.reduce(&state, .rotateSplit(ids[0]), env: env)
        #expect(state.activeSpace.splits[0].axis == .vertical)
        BrowserReducer.reduce(&state, .movePane(ids[2], to: 0), env: env)
        #expect(state.activeSpace.splits[0].tabs == [ids[2], ids[0], ids[1]])
        BrowserReducer.reduce(&state, .dissolveSplit(ids[0]), env: env)
        #expect(state.activeSpace.splits.isEmpty)
    }

    @Test func framesFillTheCardWithGaps() {
        let split = TabSplit(tabs: [TabID("a"), TabID("b"), TabID("c")], fractions: [0.5, 0.25, 0.25])
        let frames = split.frames(in: CGSize(width: 1006, height: 600), gap: 6)
        #expect(frames.map(\.width) == [497, 249, 248])
        #expect(frames[1].minX == 503 && frames[2].minX == 758)
        #expect(frames.last!.maxX == 1006)
    }

    @Test func archivingSparesTheVisibleSplit() {
        var (state, ids) = state(tabs: 3)
        BrowserReducer.reduce(&state, .splitTab(ids[0], beside: ids[1], edge: .leading), env: env)
        #expect(state.selectedTabIDs == [ids[0], ids[1]])
        BrowserReducer.reduce(&state, .archiveTabs(idleSince: .distantFuture), env: env)
        #expect(state.activeSpace.today.sorted { $0.rawValue < $1.rawValue } == [ids[0], ids[1]].sorted { $0.rawValue < $1.rawValue })
    }

    @Test func oldStateFilesLoadWithoutSplits() throws {
        let json = #"{"id":"s","name":"P","hue":0.5,"pinned":[],"today":[]}"#
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        #expect(space.splits.isEmpty)
    }
}
