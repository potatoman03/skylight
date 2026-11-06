import SkylightBrowser
import SkylightCore
import SkylightKit
import SwiftUI

// MARK: - Settings › Passwords

struct PasswordSettings: View {
    @Environment(Browser.self) private var browser
    @State private var search = ""
    @State private var importing: String?
    @State private var result: String?
    @State private var profile: ProfileID?

    var body: some View {
        let passwords = browser.passwords
        let state = browser.store.state
        let profiles = state.profiles.filter { $0.passwordsFrom == nil }
        let current = profile.flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? state.passwordProfile(for: state.activeSpace.profileID)
        let saved = passwords.logins(in: current)
        let shown = saved.filter {
            search.isEmpty || $0.displayHost.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search)
        }
        let browsers = ChromiumBrowser.installed.filter { FileManager.default.fileExists(atPath: $0.loginData.path) }
        Form {
            if profiles.count > 1 {
                Section {
                    Picker("Profile", selection: Binding(get: { current }, set: { profile = $0 })) {
                        ForEach(profiles) { Text($0.name).tag($0.id) }
                    }
                } footer: {
                    Text("Each profile has its own saved passwords, unless a Space was set up to share them. Importing and exporting use the one chosen here.")
                }
            }
            Section {
                if let error = passwords.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if shown.isEmpty {
                    Text(saved.isEmpty ? "No passwords yet." : "Nothing matches.").foregroundStyle(.secondary)
                }
                ForEach(shown) { login in
                    LoginRow(login: login)
                }
            } header: {
                HStack {
                    Text("\(saved.count) Saved Login\(saved.count == 1 ? "" : "s")")
                    Spacer()
                    TextField("Search", text: $search, prompt: Text("Search"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            } footer: {
                Text("Stored in your login Keychain. Skylight offers to save a login after you sign in, and fills it from the key in the address field.")
            }

            AutofillSection(profile: current)

            Section {
                ForEach(browsers, id: \.id) { source in
                    LabeledContent(source.name) {
                        if importing == source.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Import") {
                                importing = source.id
                                Task {
                                    result = await passwords.importFrom(source, into: current)
                                    importing = nil
                                }
                            }
                            .disabled(importing != nil)
                        }
                    }
                }
                LabeledContent {
                    Button("Choose…") { result = passwords.importFile(into: current) ?? result }
                } label: {
                    Text("Passwords file")
                    Text("From Chrome, Safari, Aside Vault, 1Password, Bitwarden and others")
                }
                if let result { Text(result).foregroundStyle(.secondary) }
            } header: {
                Text("Import")
            } footer: {
                Text("macOS asks before Skylight can read another browser's passwords. Logins you already have are kept.")
            }

            Section {
                LabeledContent("Export all logins as a CSV file") {
                    Button("Export…") { Task { await passwords.exportCSV(current) } }.disabled(saved.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LoginRow: View {
    let login: Credential
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 10) {
            Favicon(url: nil, page: URL(string: login.origin), title: login.displayHost, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(login.displayHost).lineLimit(1)
                Text(login.username.isEmpty ? "No username" : login.username)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let source = login.source {
                Text(source).font(.caption).foregroundStyle(.tertiary)
            }
            Text("••••••••").foregroundStyle(.tertiary)
            Menu {
                Button("Copy Password") { Task { await browser.passwords.copyPassword(login) } }
                Button("Copy Username") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(login.username, forType: .string)
                }
                .disabled(login.username.isEmpty)
                if let url = URL(string: login.origin) {
                    Button("Open \(login.displayHost)") { browser.store.send(.openTab(url)) }
                }
                Divider()
                Button("Delete", role: .destructive) { browser.passwords.delete(login) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

// MARK: - Address bar key

/// Shown in the address bar when the site has saved logins. Pick one to fill it.
struct LoginKeyButton: View {
    let url: URL?
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        let logins = browser.passwords.logins(for: url, in: state.passwordProfile(for: state.activeSpace.profileID))
        if !logins.isEmpty {
            Menu {
                Section("Fill a saved login") {
                    ForEach(logins) { login in
                        Button(login.username.isEmpty ? login.displayHost : login.username) { browser.fillLogin(login) }
                    }
                }
                Divider()
                Button("Manage Passwords…") { browser.openSettings("passwords") }
            } label: {
                Image(systemName: "key.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(.accentColor)
            .help("Fill a saved password")
        }
    }
}
