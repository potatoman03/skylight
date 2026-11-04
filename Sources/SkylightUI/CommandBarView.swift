import SkylightBrowser
import SwiftUI

extension Browser {
    /// Opens the command bar, growing it out of the URL pill.
    @MainActor
    public func presentCommandBar(_ mode: CommandBarModel.Mode) {
        let query = mode == .editCurrent ? (store.state.selectedTab?.url.absoluteString ?? "") : ""
        animate(Motion.grow) { commandBar.present(mode, query: query) }
    }

    @MainActor
    public func dismissCommandBar() {
        animate(Motion.exit) { commandBar.dismiss() }
        pages.focusVisiblePage()
    }
}

/// Where the bar sits inside the page card. On an empty tab it's the field in the middle of the
/// sky (and the start view puts its own field in the same place, so nothing moves).
enum CommandBarLayout {
    static let fieldHeight: CGFloat = 56

    static func top(in height: CGFloat, empty: Bool) -> CGFloat {
        empty ? max(60, height * 0.34) : min(120, max(40, height * 0.14))
    }

    static func width(in width: CGFloat) -> CGFloat { min(640, max(320, width - 64)) }
}

/// The scrim and the bar, centered on the page card rather than the window. The bar shares its
/// geometry with the URL pill, so it travels out of the sidebar and back.
struct CommandBarOverlay: View {
    let omnibox: Namespace.ID
    /// Where the page card starts.
    let leading: CGFloat
    var top: CGFloat = 8
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let empty = browser.store.state.selectedTab == nil
        ZStack(alignment: .topLeading) {
            (scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.32))
                .opacity(empty ? 0 : 1)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { browser.dismissCommandBar() }
                .transition(.opacity)

            GeometryReader { geo in
                CommandBarPanel(omnibox: omnibox)
                    .frame(width: CommandBarLayout.width(in: geo.size.width))
                    .frame(maxWidth: .infinity)
                    .padding(.top, CommandBarLayout.top(in: geo.size.height, empty: empty))
            }
            .padding(.leading, max(leading, 8))
            .padding(.top, top)
            .padding([.bottom, .trailing], 8)
        }
    }
}

private struct CommandBarPanel: View {
    let omnibox: Namespace.ID
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var bar = browser.commandBar
        let items = bar.items

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: bar.mode == .split ? "rectangle.split.2x1" : bar.mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $bar.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { bar.submit() }
                    .onKeyPress(.downArrow) { animate(Motion.feedback) { bar.moveSelection(1) }; return .handled }
                    .onKeyPress(.upArrow) { animate(Motion.feedback) { bar.moveSelection(-1) }; return .handled }
                    .onKeyPress(.escape) { browser.dismissCommandBar(); return .handled }
            }
            .padding(.horizontal, 18)
            .frame(height: CommandBarLayout.fieldHeight)

            if !items.isEmpty {
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CommandRow(item: item, highlighted: index == bar.selection)
                            .onTapGesture { bar.submit(item) }
                            .onHover { if $0 { bar.selection = index } }
                    }
                }
                .padding(6)
                .transition(Arrive(anchor: .top, scale: 0.98))
            }
        }
        .motion(Motion.travel, value: items.map(\.id))
        .glassEffect(.regular.tint(Surface.field.fill(scheme)), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Surface.field.edge(scheme), lineWidth: 0.75))
        .shadow(color: Theme.shadow(palette, scheme), radius: 40, y: 18)
        .matchedGeometryEffect(id: "omnibox", in: omnibox)
        .transition(.opacity)
        .onAppear {
            focused = true
            // ⌘L selects the current address so typing replaces it.
            if bar.mode == .editCurrent {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
        }
        .onExitCommand { browser.dismissCommandBar() }
    }
}

private struct CommandRow: View {
    let item: CommandItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.kind == .tab || item.kind == .address {
                    Favicon(url: item.faviconURL, page: item.pageURL, title: item.title)
                } else {
                    Image(systemName: item.symbol).font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 18)
            .foregroundStyle(highlighted ? .primary : .secondary)

            Text(item.title).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if highlighted {
                Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .surface(highlighted ? .selected : nil, radius: 12)
        .contentShape(.rect)
    }
}
