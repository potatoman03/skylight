import Testing
@testable import SkylightCore

@Suite struct MenuNavigationTests {
    @Test func startsAtTheEndNearestTheKey() {
        #expect(MenuNavigation.step(from: nil, by: 1, enabled: [true, true, true]) == 0)
        #expect(MenuNavigation.step(from: nil, by: -1, enabled: [true, true, true]) == 2)
    }

    @Test func wrapsAtBothEnds() {
        #expect(MenuNavigation.step(from: 2, by: 1, enabled: [true, true, true]) == 0)
        #expect(MenuNavigation.step(from: 0, by: -1, enabled: [true, true, true]) == 2)
    }

    @Test func skipsDisabledRows() {
        #expect(MenuNavigation.step(from: 0, by: 1, enabled: [true, false, true]) == 2)
        #expect(MenuNavigation.step(from: nil, by: 1, enabled: [false, false, true]) == 2)
        #expect(MenuNavigation.step(from: 2, by: 1, enabled: [false, false, true]) == 2)
    }

    @Test func staysPutWithNothingToMoveTo() {
        #expect(MenuNavigation.step(from: nil, by: 1, enabled: [false, false]) == nil)
        #expect(MenuNavigation.step(from: nil, by: -1, enabled: []) == nil)
    }
}
