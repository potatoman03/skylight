import AppKit
import SwiftUI

/// Motion tokens. System springs throughout: they start from the current velocity, so a change
/// that interrupts another one carries on smoothly instead of jumping.
/// - Only SwiftUI's own views animate. The pages are AppKit views that resize at once, so anything
///   drawn over them (dividers, grips) follows them without animating.
/// - Feedback is fast; arrivals are a touch slower than exits.
enum Motion {
    /// Hover and press feedback.
    static let feedback = Animation.easeOut(duration: 0.12)
    /// Something already on screen moving to a new place: rows making room, the selection.
    static let travel = Animation.smooth(duration: 0.28)
    /// Something arriving: palettes, toasts, results.
    static let arrive = Animation.snappy(duration: 0.26)
    /// Leaving is quicker than arriving.
    static let exit = Animation.easeOut(duration: 0.16)
    /// Body swaps inside the window (switching Space): a quick crossfade.
    static let swap = Animation.easeInOut(duration: 0.18)
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
