import SkylightBrowser
import SkylightCore
import SwiftUI

extension Browser {
    /// ⌘L edits the address in the toolbar; ⌘T (and a new split pane) opens the command bar in the
    /// middle of the page.
    @MainActor
    public func presentCommandBar(_ mode: CommandBarModel.Mode) {
        let query = mode == .editCurrent ? (store.state.selectedTab?.url.absoluteString ?? "") : ""
        commandBar.present(mode, query: query)
    }

    @MainActor
    public func dismissCommandBar() {
        guard commandBar.isPresented else { return }
        commandBar.dismiss()
        pages.focusVisiblePage()
    }
}

/// The address field in the toolbar, as in Safari: the site when you're reading, the full address
/// (selected) when you click it, with suggestions below while you type.
struct AddressField: View {
    @Environment(Browser.self) private var browser
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var bar = browser.commandBar
        let tab = browser.store.state.selectedTab
        let status = browser.selectedStatus
        let editing = bar.isPresented && bar.mode == .editCurrent

        // At rest, just where you are: the site, then the page's title. Click to type.
        HStack(spacing: 8) {
            if editing {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search or enter website name", text: $bar.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { bar.submit() }
                    .onKeyPress(.downArrow) { bar.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { bar.moveSelection(-1); return .handled }
                    .onKeyPress(.escape) { browser.dismissCommandBar(); return .handled }
            } else if let tab {
                Text(Self.display(tab))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(1)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                Text(tab.shortTitle)
                    .foregroundStyle(.secondary)
                    .fadingTail()
                LoginKeyButton(url: tab.url)
            } else {
                Text("Search or enter website name")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(minWidth: 220, idealWidth: 520, maxWidth: 640, alignment: .leading)
        .background(editing ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        }
        // Loading shows as a hairline under the address.
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Capsule()
                    .fill(.tint)
                    .frame(width: geo.size.width * max(status.progress, 0.05), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(status.isLoading && !editing ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: status.progress)
            }
            .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .onTapGesture { if !editing { browser.presentCommandBar(.editCurrent) } }
        .onChange(of: editing) { _, now in
            focused = now
            // ⌘L selects the address so typing replaces it.
            if now { DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
        }
        .onChange(of: focused) { _, now in
            // Clicking away (into the page, say) puts the address back.
            if !now, editing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !focused, browser.commandBar.mode == .editCurrent { browser.commandBar.dismiss() }
                }
            }
        }
        .accessibilityLabel("Address and search")
    }

    static func display(_ tab: BrowserTab) -> String {
        guard let host = tab.url.host(percentEncoded: false) else { return tab.displayTitle }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Suggestions under the address field while you type, styled like a menu.
struct SuggestionsList: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let bar = browser.commandBar
        let items = bar.isPresented && bar.mode == .editCurrent ? bar.items : []
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    SuggestionRow(item: item, highlighted: index == bar.selection)
                        .onTapGesture { bar.submit(item) }
                        .onHover { if $0 { bar.selection = index } }
                }
            }
            .padding(5)
            .frame(width: 560)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .padding(.top, 6)
            .transition(.opacity)
        }
    }
}

private struct SuggestionRow: View {
    let item: CommandItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if item.kind == .tab || item.kind == .address {
                    Favicon(url: item.faviconURL, page: item.pageURL, title: item.title)
                } else {
                    Image(systemName: item.symbol)
                }
            }
            .frame(width: 16)
            Text(item.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.callout).foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
        .contentShape(.rect)
    }
}

/// ⌘T: a search field in the middle of the page with tabs, sites and commands under it. Type,
/// arrow to a row (or point at it), and press Return.
struct CommandPalette: View {
    @Environment(Browser.self) private var browser
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var bar = browser.commandBar
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Clicking outside closes it.
                Color.black.opacity(0.06)
                    .contentShape(.rect)
                    .onTapGesture { browser.dismissCommandBar() }

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: bar.mode == .split ? "rectangle.split.2x1" : "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        TextField(bar.mode == .split ? "Open beside this tab" : "Search or enter website name", text: $bar.query)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .focused($focused)
                            .onSubmit { bar.submit() }
                            .onKeyPress(.downArrow) { bar.moveSelection(1); return .handled }
                            .onKeyPress(.upArrow) { bar.moveSelection(-1); return .handled }
                            .onKeyPress(.escape) { browser.dismissCommandBar(); return .handled }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 54)

                    if !bar.items.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(bar.items.enumerated()), id: \.element.id) { index, item in
                                    PaletteRow(item: item, highlighted: index == bar.selection)
                                        .onTapGesture { bar.submit(item) }
                                        .onHover { if $0 { bar.selection = index } }
                                }
                            }
                            .padding(6)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: min(420, geo.size.height * 0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: min(640, geo.size.width - 48))
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .shadow(color: .black.opacity(0.2), radius: 30, y: 14)
                .padding(.top, max(40, geo.size.height * 0.18))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: focused) { _, now in
            if !now { DispatchQueue.main.async { focused = browser.commandBar.isPresented } }
        }
    }
}

private struct PaletteRow: View {
    let item: CommandItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.kind == .tab || item.kind == .address {
                    Favicon(url: item.faviconURL, page: item.pageURL, title: item.title)
                } else {
                    Image(systemName: item.symbol)
                }
            }
            .frame(width: 18)
            Text(item.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.callout)
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            if highlighted {
                Image(systemName: "return").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}
