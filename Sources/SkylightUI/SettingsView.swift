import AppKit
import SkylightBrowser
import SkylightCore
import SkylightKit
import SwiftUI

/// Settings, in their own window with a tab for each section in the toolbar, like Safari's.
@MainActor
public final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    public init(browser: Browser) {
        tabs.tabStyle = .toolbar
        for section in SettingsSection.allCases {
            let host = NSHostingController(rootView: section.view.environment(browser).frame(width: 680, height: 560))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            item.identifier = section.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("SkylightSettings")
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the window, at `section` if one is named.
    public func show(_ section: String?) {
        if let section, let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == section }) {
            tabs.selectedTabViewItemIndex = index
        }
        window?.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, spaces, profiles, passwords, extensions, importing = "import", agents, packages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .passwords: "Passwords"
        case .spaces: "Spaces"
        case .profiles: "Profiles"
        case .importing: "Import"
        case .agents: "Agents"
        case .extensions: "Extensions"
        case .packages: "Packages"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .passwords: "key"
        case .spaces: "square.stack"
        case .profiles: "person.2"
        case .importing: "square.and.arrow.down"
        case .agents: "sparkles"
        case .extensions: "puzzlepiece.extension"
        case .packages: "shippingbox"
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .passwords: PasswordSettings()
        case .spaces: SpacesSettings()
        case .profiles: ProfilesSettings()
        case .importing: ImportSettings()
        case .agents: AgentSettings()
        case .extensions: ExtensionSettings()
        case .packages: PackageSettings()
        }
    }
}

private struct GeneralSettings: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        @Bindable var prefs = browser.preferences
        Form {
            Picker("Search with", selection: $prefs.searchEngine) {
                ForEach(Preferences.SearchEngine.allCases) { Text($0.name).tag($0) }
            }
            Picker("Archive Today tabs after", selection: $prefs.archiveAfterHours) {
                Text("6 hours").tag(6.0)
                Text("12 hours").tag(12.0)
                Text("1 day").tag(24.0)
                Text("3 days").tag(72.0)
                Text("1 week").tag(168.0)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpacesSettings: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        Form {
            ForEach(state.spaces) { space in
                SpaceSettingsRow(space: space, profiles: state.profiles, deletable: state.spaces.count > 1)
            }
            Button("New Space") { browser.store.send(.createSpace(name: "Space \(state.spaces.count + 1)")) }
        }
        .formStyle(.grouped)
    }
}

private struct SpaceSettingsRow: View {
    let space: Space
    let profiles: [Profile]
    let deletable: Bool
    @Environment(Browser.self) private var browser
    @State private var name = ""
    @State private var hue = 0.0

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Menu {
                    ForEach(SpaceMenu.icons, id: \.symbol) { icon in
                        Button { browser.store.send(.setSpaceIcon(space.id, icon.symbol)) } label: { Label(icon.name, systemImage: icon.symbol) }
                    }
                } label: {
                    SpaceIcon(icon: space.icon, name: space.name, size: 14).foregroundStyle(Theme.accent(space.hue))
                }
                .menuIndicator(.hidden)
                .fixedSize()
                TextField("Name", text: $name)
                    .onSubmit { browser.store.send(.renameSpace(space.id, name)) }
                if deletable {
                    Button(role: .destructive) { browser.store.send(.deleteSpace(space.id)) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete Space and its tabs")
                }
            }
            HStack {
                Text("Color")
                Slider(value: $hue, in: 0...1) { editing in
                    if !editing { browser.store.send(.setSpaceHue(space.id, hue)) }
                }
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Theme.skyTop(hue, .light), Theme.skyBottom(hue, .light)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 28, height: 18)
            }
            Picker("Profile", selection: Binding(get: { space.profileID }, set: { browser.store.send(.assignProfile(space.id, $0)) })) {
                ForEach(profiles) { Text($0.name).tag($0.id) }
            }
            Picker("Sky", selection: Binding(get: { space.themeID }, set: { browser.store.send(.setSpaceTheme(space.id, $0)) })) {
                Text("Same as the app").tag(String?.none)
                Divider()
                ForEach(browser.preferences.themes) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        .onAppear { name = space.name; hue = space.hue }
        .onChange(of: space.name) { _, new in name = new }
    }
}

private struct ProfilesSettings: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        Form {
            Section {
            } footer: {
                Text("Each profile has its own cookies, logins and site data. Spaces on the same profile share them, so you sign in once. Choose a Space's profile in Spaces.")
            }
            ForEach(state.profiles) { profile in
                ProfileSection(profile: profile, spaces: state.spaces.filter { $0.profileID == profile.id })
            }
            Button("New Profile") { browser.store.send(.createProfile(name: "Profile \(state.profiles.count + 1)")) }
        }
        .formStyle(.grouped)
    }
}

private struct ProfileSection: View {
    let profile: Profile
    let spaces: [Space]
    @Environment(Browser.self) private var browser
    @State private var name = ""

    static let icons = ["person.fill", "briefcase.fill", "house.fill", "graduationcap.fill", "hammer.fill", "gamecontroller.fill",
                        "heart.fill", "star.fill", "😎", "🧪", "🏝️", "🚀"]
    static let hues: [Double?] = [nil, 0.0, 0.07, 0.13, 0.33, 0.5, 0.58, 0.7, 0.8, 0.9]

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Self.icons, id: \.self) { icon in
                        Button { browser.store.send(.setProfileIcon(profile.id, icon)) } label: {
                            if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                                Label(icon, systemImage: icon)
                            } else {
                                Text(icon)
                            }
                        }
                    }
                    Divider()
                    Button("Initial") { browser.store.send(.setProfileIcon(profile.id, nil)) }
                } label: {
                    ProfileBadge(profile: profile, size: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Choose an icon")
                TextField("Name", text: $name)
                    .onSubmit { browser.store.send(.renameProfile(profile.id, name)) }
                if profile.id != .standard {
                    Button(role: .destructive) { browser.store.send(.deleteProfile(profile.id)) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete profile. Its Spaces move to Default.")
                }
            }
            LabeledContent("Color") {
                HStack(spacing: 6) {
                    ForEach(Array(Self.hues.enumerated()), id: \.offset) { _, hue in
                        Button { browser.store.send(.setProfileHue(profile.id, hue)) } label: {
                            Circle()
                                .fill(hue.map { AnyShapeStyle(Theme.accent($0).gradient) } ?? AnyShapeStyle(Color.gray.opacity(0.35)))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.primary.opacity(profile.hue == hue ? 0.7 : 0), lineWidth: 1.5).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(hue == nil ? "No color" : "")
                    }
                }
            }
            LabeledContent("Used by", value: spaces.isEmpty ? "No Spaces" : spaces.map(\.name).joined(separator: ", "))
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, new in name = new }
    }
}

/// A profile's badge: its icon or initial on its color.
struct ProfileBadge: View {
    let profile: Profile
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle().fill(profile.hue.map { AnyShapeStyle(Theme.accent($0).gradient) } ?? AnyShapeStyle(Color.gray.opacity(0.28)))
            if let icon = profile.icon {
                SpaceIcon(icon: icon, size: size * 0.5)
            } else {
                Text(profile.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.52, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(profile.hue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
        .frame(width: size, height: size)
    }
}

private struct ImportSettings: View {
    @Environment(Browser.self) private var browser
    @State private var results: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(Browser.ImportSource.allCases, id: \.self) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.rawValue)
                            Text(results[source.rawValue] ?? (source.isAvailable ? source.summary : "Not found on this Mac"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import") { results[source.rawValue] = browser.importBrowser(source) }
                            .disabled(!source.isAvailable)
                    }
                }
            } footer: {
                Text("Importing adds to what's here. Tabs you already have are skipped.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

}

private struct AgentSettings: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        Form {
            Section("Model Context Protocol") {
                LabeledContent("Server", value: browser.mcpConnection?.url ?? "Not running")
                Button("Copy Claude Code Command") { browser.copyMCPCommand() }
                    .disabled(browser.mcpConnection == nil)
                if !browser.prompts.trustedClients.isEmpty {
                    LabeledContent("Allowed without asking", value: browser.prompts.trustedClients.sorted().joined(separator: ", "))
                    Button("Ask Before Agents Act Again") { browser.prompts.revokeTrust() }
                }
            }
            Section("Recent Activity") {
                if browser.agents.activity.isEmpty {
                    Text("No agent has used Skylight yet.").foregroundStyle(.secondary)
                }
                ForEach(browser.agents.activity.prefix(12)) { item in
                    HStack {
                        Image(systemName: item.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(item.succeeded ? Color.secondary : Color.orange)
                        Text("\(item.client) · \(item.tool)").lineLimit(1)
                        Spacer()
                        Text(item.date, style: .time).foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PackageSettings: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        Form {
            Section {
                if browser.packages.packages.isEmpty {
                    Text("No packages yet. Boost a site (⌘⇧B) to make one.").foregroundStyle(.secondary)
                }
                ForEach(browser.packages.packages, id: \.id) { pkg in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pkg.manifest.name)
                            Text(pkg.manifest.matches.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Show") { browser.packages.revealInFinder(pkg) }.buttonStyle(.borderless)
                    }
                }
                ForEach(browser.packages.failures.sorted(by: { $0.key < $1.key }), id: \.key) { name, message in
                    LabeledContent(name) { Text(message).foregroundStyle(.orange).lineLimit(2) }
                }
            }
            Button("Show Packages Folder") { browser.packages.revealInFinder() }
        }
        .formStyle(.grouped)
    }
}
