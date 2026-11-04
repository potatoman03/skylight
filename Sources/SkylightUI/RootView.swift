import SkylightBrowser
import SwiftUI

/// The whole window: backdrop, sidebar, page card, and the command bar above them.
public struct RootView: View {
    @Environment(Browser.self) private var browser
    @Namespace private var omnibox

    public init() {}

    public var body: some View {
        let hue = browser.store.state.activeSpace.hue
        ZStack {
            SpaceBackdrop(hue: hue)

            HStack(spacing: 0) {
                Sidebar(omnibox: omnibox)
                    .frame(width: 252)
                ContentArea()
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
            }

            if browser.commandBar.isPresented {
                CommandBarOverlay(omnibox: omnibox)
                    .zIndex(1)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 480)
    }
}
