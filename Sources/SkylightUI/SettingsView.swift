import SkylightBrowser
import SkylightCore
import SkylightKit
import SwiftUI

/// The settings page, `skylight://settings[/section]`, drawn in the page card like any tab.
struct SettingsPage: View {
    let url: URL
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.leading, 10)
                    .padding(.bottom, 16)
                ForEach(SettingsSection.allCases) { item in
                    SettingsNavRow(section: item, selected: item == section) {
                        animate(Motion.feedback) { section = item }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 36)
            .frame(width: 220)
            .background(.primary.opacity(0.025))

            Rectangle().fill(.primary.opacity(0.06)).frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 20)
                    .padding(.top, 36)
                    .padding(.bottom, 4)
                Group {
                    switch section {
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
                .scrollContentBackground(.hidden)
                .id(section)
                .transition(Arrive(scale: 1, rise: 6))
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(.background)
        .onAppear { section = SettingsSection(path: url.lastPathComponent) ?? .general }
        .onChange(of: url) { _, new in section = SettingsSection(path: new.lastPathComponent) ?? section }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, spaces, profiles, passwords, extensions, importing = "import", agents, packages

    var id: String { rawValue }

    init?(path: String) { self.init(rawValue: path) }

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
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .passwords: "key.fill"
        case .spaces: "square.stack.fill"
        case .profiles: "person.2.fill"
        case .importing: "square.and.arrow.down.fill"
        case .agents: "sparkles"
        case .extensions: "puzzlepiece.extension.fill"
        case .packages: "shippingbox.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .indigo
        case .passwords: .teal
        case .spaces: .blue
        case .profiles: .purple
        case .importing: .green
        case .agents: .orange
        case .extensions: .cyan
        case .packages: .pink
        }
    }
}

private struct SettingsNavRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(section.color.gradient, in: .rect(cornerRadius: 6, style: .continuous))
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0), in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
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
            Picker("Appearance", selection: $prefs.appearance) {
                ForEach(Preferences.Appearance.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Themes, sidebar and layout") {
                Button("Appearance…") { browser.openSettings("appearance") }
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
                    ForEach(SpaceMenu.icons, id: \.self) { icon in
                        Button { browser.store.send(.setSpaceIcon(space.id, icon)) } label: { Label(icon, systemImage: icon) }
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
            Picker("Theme", selection: Binding(get: { space.themeID }, set: { browser.store.send(.setSpaceTheme(space.id, $0)) })) {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Each profile has its own cookies, logins and site data. Spaces on the same profile share them, so you sign in once. Click a Space to move it to a profile.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(state.profiles) { profile in
                    ProfileCard(profile: profile, spaces: state.spaces)
                }
                Button {
                    animate(Motion.swap) { _ = browser.store.send(.createProfile(name: "Profile \(state.profiles.count + 1)")) }
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
            }
            .padding(20)
        }
    }
}

private struct ProfileCard: View {
    let profile: Profile
    let spaces: [Space]
    @Environment(Browser.self) private var browser
    @State private var name = ""

    static let icons = ["person.fill", "briefcase.fill", "house.fill", "graduationcap.fill", "hammer.fill", "gamecontroller.fill",
                        "heart.fill", "star.fill", "😎", "🧪", "🏝️", "🚀"]
    static let hues: [Double?] = [nil, 0.0, 0.07, 0.13, 0.33, 0.5, 0.58, 0.7, 0.8, 0.9]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
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
                    ProfileBadge(profile: profile, size: 34)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Choose an icon")

                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .onSubmit { browser.store.send(.renameProfile(profile.id, name)) }
                    HStack(spacing: 5) {
                        ForEach(Array(Self.hues.enumerated()), id: \.offset) { _, hue in
                            Button { browser.store.send(.setProfileHue(profile.id, hue)) } label: {
                                Circle()
                                    .fill(hue.map { AnyShapeStyle(Theme.accent($0).gradient) } ?? AnyShapeStyle(Color.gray.opacity(0.35)))
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().strokeBorder(.primary.opacity(profile.hue == hue ? 0.7 : 0), lineWidth: 1.5).padding(-2.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                if profile.id != .standard {
                    Button(role: .destructive) {
                        animate(Motion.swap) { _ = browser.store.send(.deleteProfile(profile.id)) }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete profile. Its Spaces move to Default.")
                }
            }

            // Every Space as a chip: lit when it uses this profile; click to move it here.
            FlowChips(spaces: spaces, profileID: profile.id)
        }
        .padding(14)
        .settingsCard()
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, new in name = new }
    }
}

private struct FlowChips: View {
    let spaces: [Space]
    let profileID: ProfileID
    @Environment(Browser.self) private var browser

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(spaces) { space in
                let here = space.profileID == profileID
                Button {
                    if !here { animate(Motion.swap) { _ = browser.store.send(.assignProfile(space.id, profileID)) } }
                } label: {
                    HStack(spacing: 6) {
                        SpaceIcon(icon: space.icon, name: space.name, size: 10).foregroundStyle(Theme.accent(space.hue))
                        Text(space.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        if here { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(.primary.opacity(here ? 0.09 : 0.03), in: .capsule)
                    .opacity(here ? 1 : 0.7)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(here ? "\(space.name) uses this profile" : "Move \(space.name) to this profile")
            }
        }
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
