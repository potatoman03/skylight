import Foundation

/// Reads the scroll events of a two-finger swipe as one step between Spaces. Stays out of the way
/// of vertical scrolling: until a gesture has shown its direction its events carry on to whatever
/// is under the pointer, and a vertical one is left alone until the fingers lift.
public struct SpaceSwipe: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case began
        case moved(x: Double, y: Double)
        case ended
        case cancelled
        /// The scroll that carries on after the fingers lift. `last` is its final event.
        case momentum(last: Bool)
    }

    public enum Response: Equatable, Sendable {
        /// Not ours: the event goes on to whatever is under the pointer.
        case pass
        /// Part of a swipe: nothing else should see it.
        case consume
        /// The fingers lifted. `step` is the Space to move by, or nil to stay. The event still goes
        /// on, so a scroll view that saw the gesture begin also sees it end.
        case finished(step: Int?)
    }

    private enum Stage: Equatable, Sendable {
        case idle
        case deciding(x: Double, y: Double)
        case scrolling
        case swiping
        /// The fingers have lifted from a swipe. Its momentum belongs to it, not to the list.
        case coasting
    }

    /// How far the fingers move before the gesture's direction counts.
    static let decision = 8.0
    /// A swipe is this much wider than it is tall: scrolling a list is rarely dead straight.
    static let slope = 1.5
    /// How far a swipe travels to change Space.
    static let distance = 60.0
    /// A shorter swipe still counts if it's flicked: this far, moving this fast as the fingers lift.
    static let flickDistance = 20.0
    static let flickSpeed = 6.0

    private var stage = Stage.idle
    private var lastMove = 0.0

    /// How far the fingers have gone, in points, in the direction the content would scroll. Zero
    /// unless a swipe is under way.
    public private(set) var travel = 0.0

    public init() {}

    /// Whether a swipe has started and hasn't finished, so its events must keep coming here
    /// wherever the pointer is.
    public var isActive: Bool { stage != .idle && stage != .scrolling }

    public mutating func handle(_ event: Event) -> Response {
        switch (event, stage) {
        case (.began, _):
            self = SpaceSwipe()
            stage = .deciding(x: 0, y: 0)
            return .pass

        case let (.moved(x, y), .deciding(soFar, up)):
            let (x, y) = (soFar + x, up + y)
            guard max(abs(x), abs(y)) >= Self.decision else {
                stage = .deciding(x: x, y: y)
                return .pass
            }
            guard abs(x) >= abs(y) * Self.slope else {
                stage = .scrolling
                return .pass
            }
            stage = .swiping
            travel = x
            lastMove = x
            return .consume

        case let (.moved(x, _), .swiping):
            travel += x
            lastMove = x
            return .consume

        case (.ended, .swiping):
            let step = self.step
            stage = .coasting
            travel = 0
            return .finished(step: step)

        case (.cancelled, .swiping):
            self = SpaceSwipe()
            return .finished(step: nil)

        case (.ended, _), (.cancelled, _):
            self = SpaceSwipe()
            return .pass

        case let (.momentum(last), .coasting):
            if last { self = SpaceSwipe() }
            return .consume

        default:
            return .pass
        }
    }

    /// Content moves left to bring in what's to its right, so a negative scroll is the next Space.
    private var step: Int? {
        let flicked = abs(travel) >= Self.flickDistance && abs(lastMove) >= Self.flickSpeed && lastMove * travel > 0
        guard abs(travel) >= Self.distance || flicked else { return nil }
        return travel < 0 ? 1 : -1
    }

    /// How far to move the list with the fingers: less and less the further they go, and hardly at
    /// all with no Space that way to go to.
    public func shift(canMove: Bool) -> Double {
        let limit = canMove ? 32.0 : 10.0
        let eased = limit * (1 - 1 / (abs(travel) / (limit * 2) + 1))
        return travel < 0 ? -eased : eased
    }

    /// Whether the swipe is going to the next Space (1) or the previous one (-1).
    public var direction: Int { travel < 0 ? 1 : -1 }
}
