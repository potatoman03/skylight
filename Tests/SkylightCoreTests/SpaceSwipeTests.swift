import Testing
@testable import SkylightCore

@Suite struct SpaceSwipeTests {
    /// Sends a gesture's moves, all the same size, and returns the last response.
    @discardableResult
    func move(_ swipe: inout SpaceSwipe, x: Double, y: Double = 0, times: Int) -> SpaceSwipe.Response {
        var response = SpaceSwipe.Response.pass
        for _ in 0..<times { response = swipe.handle(.moved(x: x, y: y)) }
        return response
    }

    func swipe(x: Double, times: Int) -> SpaceSwipe.Response {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        move(&swipe, x: x, times: times)
        return swipe.handle(.ended)
    }

    @Test func aLongSwipeMovesOneSpaceEitherWay() {
        #expect(swipe(x: -4, times: 40) == .finished(step: 1))
        #expect(swipe(x: 4, times: 40) == .finished(step: -1))
    }

    @Test func aShortSlowSwipeStays() {
        #expect(swipe(x: -2, times: 20) == .finished(step: nil))
    }

    @Test func aShortFlickCounts() {
        #expect(swipe(x: -8, times: 4) == .finished(step: 1))
    }

    @Test func pullingBackBeforeLiftingStays() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        move(&swipe, x: -5, times: 20)
        move(&swipe, x: 5, times: 19)
        #expect(swipe.handle(.ended) == .finished(step: nil))
    }

    @Test func aFlickBackDoesNotCount() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        move(&swipe, x: -5, times: 8)
        move(&swipe, x: 8, times: 1)
        #expect(swipe.handle(.ended) == .finished(step: nil))
    }

    @Test func eventsPassUntilTheDirectionIsKnown() {
        var swipe = SpaceSwipe()
        #expect(swipe.handle(.began) == .pass)
        #expect(swipe.handle(.moved(x: -3, y: 0)) == .pass)
        #expect(swipe.handle(.moved(x: -3, y: 0)) == .pass)
        #expect(swipe.handle(.moved(x: -3, y: 0)) == .consume)
    }

    @Test func verticalScrollingIsLeftAlone() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        #expect(move(&swipe, x: 0, y: -4, times: 3) == .pass)
        // Drifting sideways later doesn't turn it into a swipe.
        #expect(move(&swipe, x: -10, y: 0, times: 20) == .pass)
        #expect(swipe.travel == 0)
        #expect(swipe.handle(.ended) == .pass)
        #expect(swipe.handle(.momentum(last: false)) == .pass)
    }

    @Test func aDiagonalCountsAsScrolling() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        #expect(move(&swipe, x: -5, y: -5, times: 4) == .pass)
        #expect(!swipe.isActive)
    }

    @Test func momentumAfterASwipeIsSwallowedAndDoesNotSwitchAgain() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        move(&swipe, x: -10, times: 10)
        #expect(swipe.handle(.ended) == .finished(step: 1))
        #expect(swipe.isActive)
        #expect(swipe.handle(.momentum(last: false)) == .consume)
        #expect(swipe.handle(.moved(x: -30, y: 0)) == .pass)
        #expect(swipe.handle(.momentum(last: true)) == .consume)
        #expect(!swipe.isActive)
    }

    @Test func aNewSwipeCanStartDuringMomentum() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        move(&swipe, x: -10, times: 10)
        _ = swipe.handle(.ended)
        _ = swipe.handle(.momentum(last: false))
        #expect(swipe.handle(.began) == .pass)
        move(&swipe, x: 10, times: 10)
        #expect(swipe.handle(.ended) == .finished(step: -1))
    }

    @Test func cancellingStays() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        move(&swipe, x: -10, times: 10)
        #expect(swipe.handle(.cancelled) == .finished(step: nil))
        #expect(!swipe.isActive)
        #expect(swipe.travel == 0)
    }

    @Test func eventsOutsideAGestureAreNotOurs() {
        var swipe = SpaceSwipe()
        #expect(swipe.handle(.moved(x: -100, y: 0)) == .pass)
        #expect(swipe.handle(.ended) == .pass)
        #expect(swipe.handle(.momentum(last: true)) == .pass)
    }

    @Test func theListFollowsLessAndLessAndBarelyAtTheEnds() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(.began)
        move(&swipe, x: -10, times: 3)
        let near = swipe.shift(canMove: true)
        move(&swipe, x: -10, times: 30)
        let far = swipe.shift(canMove: true)
        #expect(near < 0)
        #expect(far < near)
        #expect(far > -32)
        #expect(swipe.shift(canMove: false) > far)
        #expect(swipe.shift(canMove: false) > -10)
        #expect(swipe.direction == 1)
    }
}
