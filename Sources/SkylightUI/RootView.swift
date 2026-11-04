import AppKit
import SkylightBrowser
import SwiftUI

/// The whole window: the sky, the sidebar, the page card, and the command bar above them.
///
/// The window controls (traffic lights, sidebar toggle, back, forward, reload) sit in one fixed row
/// at the top left, centered on the traffic lights. They don't move when the sidebar hides, peeks
/// or comes back.
public struct RootView: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @Namespace private var omnibox
    @State private var peeking = false
    @State private var lights = TrafficLights()

    static let sidebarWidth: CGFloat = 252

    public init() {}

    public var body: some View {
        let hue = browser.store.state.activeSpace.hue
        let collapsed = browser.preferences.sidebarCollapsed
        let row = lights.rowHeight

        ZStack(alignment: .topLeading) {
            SkyBackdrop(hue: hue, rays: browser.preferences.godRays)

            HStack(spacing: 0) {
                if !collapsed {
                    Sidebar(omnibox: omnibox, topInset: row + 6)
                        .frame(width: Self.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                // With the sidebar hidden, the controls keep a thin strip of sky above the page.
                ContentArea()
                    .padding(.top, collapsed ? row : 8)
                    .padding([.bottom, .trailing], 8)
                    .padding(.leading, collapsed ? 8 : 0)
            }

            // With the sidebar hidden, it slides back over the page while the pointer is at the edge.
            if collapsed {
                Color.clear
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .padding(.top, row)
                    .contentShape(.rect)
                    .onHover { if $0 { animate(Motion.arrive) { peeking = true } } }
                if peeking {
                    Sidebar(omnibox: omnibox, topInset: row)
                        .frame(width: Self.sidebarWidth)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                            ZStack {
                                SkyBackdrop(hue: hue, rays: false)
                                Rectangle().fill(.white.opacity(scheme == .dark ? 0.02 : 0.2))
                            }
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(Surface.selected.edge(scheme), lineWidth: 0.75))
                            .shadow(color: Theme.shadow(hue, scheme), radius: 30, x: 8)
                        }
                        .padding([.leading, .bottom], 6)
                        .padding(.top, 6)
                        .onHover { if !$0 { animate(Motion.exit) { peeking = false } } }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }
            }

            WindowControls(lights: lights, collapsed: collapsed)
                .zIndex(2)

            if browser.commandBar.isPresented {
                CommandBarOverlay(omnibox: omnibox, leading: collapsed ? 0 : Self.sidebarWidth, top: collapsed ? row : 8)
                    .zIndex(3)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .background(TrafficLightReader(lights: $lights))
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: collapsed) { _, now in if !now { peeking = false } }
    }
}

/// Where macOS put the traffic lights, so our controls line up with them exactly.
struct TrafficLights: Equatable {
    var centerY: CGFloat = 16
    var trailingX: CGFloat = 78

    /// A row centered on the lights.
    var rowHeight: CGFloat { centerY * 2 }
}

private struct WindowControls: View {
    let lights: TrafficLights
    let collapsed: Bool
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 1) {
            Spacer().frame(width: max(0, lights.trailingX - 10))
            IconButton(symbol: "sidebar.left", help: collapsed ? "Show sidebar (⌘S)" : "Hide sidebar (⌘S)") {
                animate(Motion.travel) { browser.toggleSidebar() }
            }
            Spacer(minLength: 0)
            NavigationButtons()
        }
        .padding(.horizontal, 10)
        .frame(width: RootView.sidebarWidth, height: lights.rowHeight)
    }
}

private struct TrafficLightReader: NSViewRepresentable {
    @Binding var lights: TrafficLights

    func makeNSView(context: Context) -> LightsProbe {
        let probe = LightsProbe()
        probe.onChange = { new in if lights != new { lights = new } }
        return probe
    }

    func updateNSView(_ probe: LightsProbe, context: Context) {
        probe.onChange = { new in if lights != new { lights = new } }
    }
}

final class LightsProbe: NSView {
    var onChange: ((TrafficLights) -> Void)?
    private var last: TrafficLights?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    override func layout() {
        super.layout()
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    private func report() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let closeFrame = close.superview?.convert(close.frame, to: nil),
              let zoomFrame = zoom.superview?.convert(zoom.frame, to: nil) else { return }
        let height = window.contentView?.bounds.height ?? window.frame.height
        let lights = TrafficLights(centerY: (height - closeFrame.midY).rounded(), trailingX: (zoomFrame.maxX + 10).rounded())
        guard lights != last, lights.centerY > 4 else { return }
        last = lights
        onChange?(lights)
    }
}
