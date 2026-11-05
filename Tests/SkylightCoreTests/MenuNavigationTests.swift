import CoreGraphics
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

    @Test func findsTheRowUnderThePointer() {
        let row = { MenuNavigation.row(at: $0, sections: [2, 3], inset: 5, rowHeight: 28, divider: 9) }
        #expect(row(0) == nil)  // the padding
        #expect(row(5) == 0)
        #expect(row(60) == 1)
        #expect(row(62) == nil)  // the divider
        #expect(row(70) == 2)
        #expect(row(150) == 4)
        #expect(row(154) == nil)  // the padding at the bottom
    }

    @Test func theFunnelOpensTowardTheSubmenu() {
        // The submenu is to the left, its near edge at x = 100, from y = 0 to y = 200.
        let funnel = { (x: CGFloat, y: CGFloat) in
            MenuNavigation.isInFunnel(CGPoint(x: x, y: y), from: CGPoint(x: 300, y: 100), toEdgeAtX: 100, top: 0, bottom: 200)
        }
        #expect(funnel(200, 60))  // heading up and left, crossing the rows above
        #expect(funnel(200, 140))  // and down and left
        #expect(!funnel(290, 60))  // straight up the menu: a row you want
        #expect(!funnel(290, 140))
        #expect(!funnel(320, 100))  // moving away from the submenu
    }
}
