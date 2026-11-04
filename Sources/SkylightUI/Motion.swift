import AppKit
import SwiftUI

/// Motion tokens. The rules they encode:
/// - Nothing pops. Things arrive from where they came from, fading and un-blurring as they move.
/// - One object, one trip. The command bar is the URL pill, grown; the selection is one highlight
///   that travels between rows.
/// - Neighbors make room continuously while a newcomer arrives.
/// - Feedback is fast. Only motion that tells a story (a morph, an arrival) takes longer.
enum Motion {
    /// Hover and press feedback.
    static let feedback = Animation.timingCurve(0.3, 0.75, 0.1, 1, duration: 0.16)
    /// Something already on screen moving to a new place: rows making room, the selection.
    static let travel = Animation.timingCurve(0.45, 0, 0.1, 1, duration: 0.34)
    /// Something arriving: cards, toasts, results.
    static let arrive = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.42)
    /// Something that grows as it travels: the pill becoming the command bar.
    static let grow = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.5)
    /// Leaving is quicker than arriving.
    static let exit = Animation.timingCurve(0.3, 0.75, 0.1, 1, duration: 0.2)
    /// Body swaps inside the window (switching Space): crossfade with a small rise.
    static let swap = Animation.timingCurve(0.3, 0.75, 0.1, 1, duration: 0.22)
    /// Distant hues pass through mud; keep it short.
    static let hue = Animation.easeInOut(duration: 0.2)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The animation to use, or a short fade when Reduce Motion is on.
    static func resolved(_ animation: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : animation
    }
}

/// `withAnimation` that respects Reduce Motion.
@MainActor
func animate(_ animation: Animation, _ body: () -> Void) {
    withAnimation(Motion.resolved(animation), body)
}

/// Fades, scales and un-blurs from an anchor. With Reduce Motion it only fades.
struct Arrive: Transition {
    var anchor: UnitPoint = .center
    var scale: CGFloat = 0.96
    var rise: CGFloat = 0

    func body(content: Content, phase: TransitionPhase) -> some View {
        let reduce = Motion.reduceMotion
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(phase.isIdentity || reduce ? 1 : scale, anchor: anchor)
            .offset(y: phase.isIdentity || reduce ? 0 : rise)
            .blur(radius: phase.isIdentity || reduce ? 0 : 4)
    }
}

extension View {
    /// Implicit animation that respects Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(Motion.resolved(animation), value: value)
    }
}
