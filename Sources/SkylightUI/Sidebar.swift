import SkylightAgent
import SkylightBrowser
import SkylightCore
import SwiftUI

/// SwiftUI has its own `Tab`.
typealias BrowserTab = SkylightCore.Tab

struct Sidebar: View {
    let omnibox: Namespace.ID
    @Environment(Browser.self) private var browser
    @Namespace private var selection

    var body: some View {
        let state = browser.store.state
        let space = state.activeSpace

        VStack(alignment: .leading, spacing: 10) {
            NavigationRow()
                .frame(height: 28)
                .padding(.leading, 70) // Traffic lights.

            URLPill(omnibox: omnibox)

            // The Space's tabs swap as one body: a crossfade with a small rise, never a slide.
            VStack(alignment: .leading, spacing: 10) {
                PinnedGrid(space: space, selection: selection)
                TodayList(space: space, selection: selection)
            }
            .id(space.id)
            .transition(Arrive(scale: 1, rise: 8))
            .motion(Motion.swap, value: space.id)

            AgentActivityBadge()
            SpaceSwitcher()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

// MARK: - Navigation

private struct NavigationRow: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let status = browser.selectedStatus
        let id = browser.store.state.selectedTabID
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            IconButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: status.canGoBack) {
                if let id { browser.store.send(.goBack(id)) }
            }
            IconButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: status.canGoForward) {
                if let id { browser.store.send(.goForward(id)) }
            }
            IconButton(symbol: status.isLoading ? "xmark" : "arrow.clockwise", help: status.isLoading ? "Stop" : "Reload (⌘R)",
                       enabled: id != nil) {
                guard let id else { return }
                browser.store.send(status.isLoading ? .stop(id) : .reload(id))
            }
            .contentTransition(.symbolEffect(.replace))
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(hovering && enabled ? 0.08 : 0), in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
    }
}

/// The selected tab's address. Clicking it grows it into the command bar.
private struct URLPill: View {
    let omnibox: Namespace.ID
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let tab = browser.store.state.selectedTab
        let presented = browser.commandBar.isPresented
        ZStack {
            if !presented {
                HStack(spacing: 7) {
                    if tab?.url.scheme == "https" {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    Text(tab.map(Self.display) ?? "Search or enter address")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tab == nil ? HierarchicalShapeStyle.tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 11, style: .continuous))
                .matchedGeometryEffect(id: "omnibox", in: omnibox)
                .transition(.opacity)
            } else {
                Color.clear.frame(height: 34)
            }
        }
        .scaleEffect(hovering && !presented ? 1.01 : 1)
        .contentShape(.rect)
        .onTapGesture { browser.presentCommandBar(.editCurrent) }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
    }

    static func display(_ tab: BrowserTab) -> String {
        guard let host = tab.url.host(percentEncoded: false) else { return tab.url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Pinned

private struct PinnedGrid: View {
    let space: Space
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser

    var body: some View {
        let tabs = browser.store.state.tabs(in: space, .pinned)
        if !tabs.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(tabs) { tab in
                    PinnedTile(tab: tab, selected: space.selectedTabID == tab.id, selection: selection)
                        .transition(Arrive(scale: 0.85))
                }
            }
            .motion(Motion.travel, value: space.pinned)
        }
    }
}

private struct PinnedTile: View {
    let tab: BrowserTab
    let selected: Bool
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        Favicon(url: tab.faviconURL, title: tab.displayTitle, size: 18)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.9))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0.05))
                }
            }
            .contentShape(.rect)
            .onTapGesture { animate(Motion.travel) { _ = browser.store.send(.selectTab(tab.id)) } }
            .onHover { h in animate(Motion.feedback) { hovering = h } }
            .help(tab.displayTitle)
            .contextMenu { TabMenu(tab: tab) }
    }
}

// MARK: - Today

private struct TodayList: View {
    let space: Space
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser

    var body: some View {
        let tabs = browser.store.state.tabs(in: space, .today)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                NewTabRow()
                if !space.pinned.isEmpty || !tabs.isEmpty {
                    Divider().opacity(0.5).padding(.horizontal, 6).padding(.vertical, 4)
                }
                ForEach(tabs) { tab in
                    TabRow(tab: tab, selected: space.selectedTabID == tab.id, selection: selection)
                        .transition(Arrive(anchor: .top, scale: 0.98))
                }
            }
            .motion(Motion.travel, value: space.today)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct NewTabRow: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 16)
            Text("New Tab").font(.system(size: 13))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: Theme.rowRadius, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { browser.presentCommandBar(.newTab) }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let selected: Bool
    let selection: Namespace.ID
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let status = browser.store.status(of: tab.id)
        HStack(spacing: 9) {
            ZStack {
                if status.isLoading {
                    ProgressView().controlSize(.mini).transition(.opacity)
                } else {
                    Favicon(url: tab.faviconURL, title: tab.displayTitle).transition(.opacity)
                }
            }
            .frame(width: 16, height: 16)
            .motion(Motion.feedback, value: status.isLoading)

            Text(tab.displayTitle)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(status.isAwake || selected ? HierarchicalShapeStyle.primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button {
                    animate(Motion.travel) { _ = browser.store.send(.closeTab(tab.id)) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(.background.opacity(0.9))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    .matchedGeometryEffect(id: "selection", in: selection)
            } else if hovering {
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(.primary.opacity(0.07))
            }
        }
        .contentShape(.rect)
        .onTapGesture { animate(Motion.travel) { _ = browser.store.send(.selectTab(tab.id)) } }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .contextMenu { TabMenu(tab: tab) }
    }
}

private struct TabMenu: View {
    let tab: BrowserTab
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        let pinned = state.space(containing: tab.id)?.section(of: tab.id) == .pinned
        Button(pinned ? "Unpin" : "Pin") { animate(Motion.travel) { _ = browser.store.send(.togglePin(tab.id)) } }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
        }
        Menu("Move to Space") {
            ForEach(state.spaces.filter { !$0.contains(tab.id) }) { space in
                Button(space.name) { animate(Motion.travel) { _ = browser.store.send(.moveTabToSpace(tab.id, space.id)) } }
            }
        }
        Divider()
        Button("Close Tab") { animate(Motion.travel) { _ = browser.store.send(.closeTab(tab.id)) } }
    }
}

// MARK: - Spaces and agents

private struct SpaceSwitcher: View {
    @Environment(Browser.self) private var browser
    @State private var renaming: Space?
    @State private var newName = ""

    var body: some View {
        let state = browser.store.state
        HStack(spacing: 6) {
            Text(state.activeSpace.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .motion(Motion.swap, value: state.activeSpace.name)
            Spacer(minLength: 0)
            ForEach(state.spaces) { space in
                let active = space.id == state.activeSpaceID
                Button { animate(Motion.swap) { _ = browser.store.send(.switchSpace(space.id)) } } label: {
                    Circle()
                        .fill(Theme.dot(space.hue))
                        .frame(width: active ? 10 : 7, height: active ? 10 : 7)
                        .overlay(Circle().strokeBorder(.white.opacity(active ? 0.7 : 0), lineWidth: 1.5))
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(space.name)
                .contextMenu {
                    Button("Rename…") { newName = space.name; renaming = space }
                    if state.spaces.count > 1 {
                        Button("Delete Space", role: .destructive) { animate(Motion.swap) { _ = browser.store.send(.deleteSpace(space.id)) } }
                    }
                }
            }
            .motion(Motion.travel, value: state.activeSpaceID)
            IconButton(symbol: "plus", help: "New Space (⌘⇧N)") {
                animate(Motion.swap) { _ = browser.store.send(.createSpace(name: "Space \(state.spaces.count + 1)")) }
            }
        }
        .padding(.leading, 6)
        .alert("Rename Space", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let space = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    browser.store.send(.renameSpace(space.id, newName))
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

/// Shows the latest agent action for a few seconds.
private struct AgentActivityBadge: View {
    @Environment(Browser.self) private var browser
    @State private var visible: AgentActivity?

    var body: some View {
        ZStack {
            if let activity = visible {
                HStack(spacing: 7) {
                    Image(systemName: activity.succeeded ? "sparkles" : "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolEffect(.pulse, isActive: activity.succeeded)
                    Text("\(activity.client) · \(activity.tool.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .glassEffect(.regular, in: .capsule)
                .transition(Arrive(anchor: .bottom, scale: 0.94, rise: 6))
            }
        }
        .task(id: browser.agents.activity.first?.id) {
            guard let latest = browser.agents.activity.first, Date.now.timeIntervalSince(latest.date) < 5 else { return }
            animate(Motion.arrive) { visible = latest }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            animate(Motion.exit) { visible = nil }
        }
    }
}
