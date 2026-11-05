import AppKit
import SkylightCore
import SwiftUI

/// Watches two-finger swipes that start over the view it backs and hands them to `handle`. A local
/// monitor rather than `scrollWheel(with:)`, because the list's scroll view gets those first. Only
/// here over the sidebar: a page's sideways scrolling and Chromium's back and forward swipe never
/// come through.
struct SpaceSwipeArea: NSViewRepresentable {
    let handle: (SpaceSwipe.Event) -> SpaceSwipe.Response

    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ view: Area, context: Context) { view.handle = handle }

    final class Area: NSView {
        var handle: (SpaceSwipe.Event) -> SpaceSwipe.Response = { _ in .pass }
        private var monitor: Any?

        // Rows and buttons sit on top, and it only watches.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return consumed ? nil : event
            }
        }

        private func consumes(_ event: NSEvent) -> Bool {
            guard let gesture = SpaceSwipe.Event(event) else { return false }
            // A gesture that starts elsewhere isn't ours, and ends any swipe still coasting here.
            if gesture == .began, !isUnderPointer(event) {
                _ = handle(.cancelled)
                return false
            }
            return handle(gesture) == .consume
        }

        private func isUnderPointer(_ event: NSEvent) -> Bool {
            event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
        }
    }
}

private extension SpaceSwipe.Event {
    /// Nil for what isn't a trackpad gesture: a mouse wheel has no phases.
    init?(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return nil }
        if !event.momentumPhase.isEmpty {
            self = .momentum(last: event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled))
            return
        }
        switch event.phase {
        case .began: self = .began
        case .changed: self = .moved(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        case .ended: self = .ended
        case .cancelled: self = .cancelled
        default: return nil
        }
    }
}
