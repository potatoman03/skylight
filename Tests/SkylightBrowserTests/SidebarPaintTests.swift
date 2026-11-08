import AppKit
import QuartzCore
import Testing
@testable import SkylightBrowser

@Suite @MainActor
struct SidebarPaintTests {
    private final class VisibleTestWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState { .visible }
    }

    private func fixture() -> (window: NSWindow, host: PageHostView, painted: CALayer) {
        _ = NSApplication.shared
        let window = VisibleTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        let host = PageHostView(frame: NSRect(x: 240, y: 0, width: 1040, height: 800))
        window.contentView?.addSubview(host)
        let page = NSView()
        page.wantsLayer = true
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let painted = CALayer()
        painted.name = "overhang areas"
        painted.frame = CGRect(x: 240, y: 0, width: 1040, height: 800)
        root.addSublayer(painted)
        page.layer?.addSublayer(root)
        host.addPage(page)
        host.arrange([page], split: nil, gap: 0, radius: 0)
        return (window, host, painted)
    }

    @Test func keepsUnpaintedPageUnderTheSidebar() throws {
        let (window, host, painted) = fixture()
        host.beginSlide(closing: true, width: 240, color: .white)
        let mask = try #require(host.layer?.mask)
        #expect(abs(mask.frame.minX - 0) < 0.5)

        // The page is asked for a wider layout, but the mask may only expose what landed.
        painted.bounds.size.width = 1160
        #expect(abs(mask.frame.minX - (-120)) < 0.5)
        painted.bounds.size.width = 1280
        #expect(abs(mask.frame.minX - (-240)) < 0.5)

        host.finishSlide(afterResize: false)
        #expect(host.layer?.mask == nil)
        withExtendedLifetime(window) {}
    }

    @Test func waitsForTheFinalPaint() async throws {
        let (window, host, painted) = fixture()
        host.beginSlide(closing: true, width: 240, color: .white)
        var completed = false
        let wait = Task { await host.waitForPaintedEdge(); completed = true }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!completed)
        painted.bounds.size.width = 1280
        await wait.value
        #expect(completed)
        host.finishSlide(afterResize: false)
        withExtendedLifetime(window) {}
    }

    @Test func reversalStartsAtTheVisibleEdge() async throws {
        let (window, host, _) = fixture()
        host.beginSlide(closing: true, width: 240, color: .white)
        host.runSlide(seconds: 0.38, timing: CAMediaTimingFunction(name: .linear))
        try await Task.sleep(for: .milliseconds(100))
        host.beginSlide(closing: false, width: 240, color: .white)
        let mask = try #require(host.layer?.mask)
        let edge = try #require(mask.sublayers?.first)
        #expect(abs(mask.frame.minX + edge.frame.minX) < 0.5)
        host.finishSlide(afterResize: false)
        withExtendedLifetime(window) {}
    }

    @Test func restoresDrawingCoordinatesWhenSlideEnds() throws {
        let (window, host, painted) = fixture()
        let root = try #require(painted.superlayer)
        host.beginSlide(closing: true, width: 240, color: .white)
        painted.bounds.size.width = 900
        #expect(abs(root.sublayerTransform.m41) > 1)
        host.finishSlide(afterResize: false)
        #expect(abs(root.sublayerTransform.m41) < 0.5)
        withExtendedLifetime(window) {}
    }

    @Test func restoresTheOldRootWhenWebKitReplacesIt() throws {
        let (window, host, painted) = fixture()
        let oldRoot = try #require(painted.superlayer)
        let page = try #require(host.subviews.first)
        host.beginSlide(closing: true, width: 240, color: .white)
        painted.bounds.size.width = 900
        #expect(abs(oldRoot.sublayerTransform.m41) > 1)

        oldRoot.removeFromSuperlayer()
        let newRoot = CALayer()
        let newPainted = CALayer()
        newPainted.name = "overhang areas"
        newPainted.frame = CGRect(x: 240, y: 0, width: 1040, height: 800)
        newRoot.addSublayer(newPainted)
        page.layer?.addSublayer(newRoot)
        host.coveredWidth = 240 // A layout discovers the replacement layer tree.
        #expect(abs(oldRoot.sublayerTransform.m41) < 0.5)
        host.finishSlide(afterResize: false)
        withExtendedLifetime(window) {}
    }

    @Test func changingThePageCancelsAnInFlightSlide() throws {
        let (window, host, painted) = fixture()
        let root = try #require(painted.superlayer)
        host.beginSlide(closing: true, width: 240, color: .white)
        painted.bounds.size.width = 900
        #expect(abs(root.sublayerTransform.m41) > 1)
        let replacement = NSView()
        host.addPage(replacement)
        host.arrange([replacement], split: nil, gap: 0, radius: 0)
        #expect(host.layer?.mask == nil)
        #expect(abs(root.sublayerTransform.m41) < 0.5)
        withExtendedLifetime(window) {}
    }

    @Test func loadingCanEndThePaintWait() async throws {
        let (window, host, _) = fixture()
        host.beginSlide(closing: true, width: 240, color: .white)
        var loading = false
        var completed = false
        let wait = Task { await host.waitForPaintedEdge { !loading }; completed = true }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!completed)
        loading = true
        await wait.value
        #expect(completed)
        host.finishSlide(afterResize: false)
        withExtendedLifetime(window) {}
    }
}
