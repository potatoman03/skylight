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

    var body: some View {
        let passwords = browser.passwords
        let shown = passwords.saved.filter {
            search.isEmpty || $0.displayHost.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search)
        }
        let browsers = ChromiumBrowser.installed.filter { FileManager.default.fileExists(atPath: $0.loginData.path) }
        Form {
            Section {
                if let error = passwords.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if shown.isEmpty {
                    Text(passwords.saved.isEmpty ? "No passwords yet." : "Nothing matches.").foregroundStyle(.secondary)
                }
                ForEach(shown) { login in
                    LoginRow(login: login)
                }
            } header: {
                HStack {
                    Text("\(passwords.saved.count) Saved Login\(passwords.saved.count == 1 ? "" : "s")")
                    Spacer()
                    TextField("Search", text: $search, prompt: Text("Search"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            } footer: {
                Text("Stored in your login Keychain. Skylight offers to save a login after you sign in, and fills it from the key in the address field.")
            }

            Section {
                ForEach(browsers, id: \.id) { source in
                    LabeledContent(source.name) {
                        if importing == source.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Import") {
                                importing = source.id
                                Task {
                                    result = await passwords.importFrom(source)
                                    importing = nil
                                }
                            }
                            .disabled(importing != nil)
                        }
                    }
                }
                LabeledContent {
                    Button("Choose…") { result = passwords.importCSV() ?? result }
                } label: {
                    Text("CSV file")
                    Text("From Chrome, Safari, 1Password, Bitwarden and others")
                }
                if let result { Text(result).foregroundStyle(.secondary) }
            } header: {
                Text("Import")
            } footer: {
                Text("macOS asks before Skylight can read another browser's passwords. Logins you already have are kept.")
            }

            Section {
                LabeledContent("Export all logins as a CSV file") {
                    Button("Export…") { Task { await passwords.exportCSV() } }.disabled(passwords.saved.isEmpty)
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
        let logins = browser.passwords.logins(for: url)
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
