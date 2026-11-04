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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsBlock("Import", note: "macOS asks before Skylight can read another browser's passwords. Logins you already have are kept.") {
                    VStack(spacing: 0) {
                        let browsers = ChromiumBrowser.installed.filter { FileManager.default.fileExists(atPath: $0.loginData.path) }
                        ForEach(Array(browsers.enumerated()), id: \.element.id) { i, source in
                            if i > 0 { Divider() }
                            SettingsRow(source.name) {
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
                        if !browsers.isEmpty { Divider() }
                        SettingsRow("CSV file", note: "From Chrome, Safari, 1Password, Bitwarden and others") {
                            Button("Choose…") { result = passwords.importCSV() ?? result }
                        }
                    }
                    .settingsCard()
                    if let result { Text(result).font(.system(size: 12)).foregroundStyle(.secondary) }
                }

                SettingsBlock("Saved", note: "Stored in your login Keychain. Skylight offers to save a login after you sign in, and fills it when you pick it from the key in the address bar.") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            Spacer()
                            Text("\(passwords.saved.count) login\(passwords.saved.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                            Button("Export…") { Task { await passwords.exportCSV() } }.disabled(passwords.saved.isEmpty)
                        }
                        if let error = passwords.lastError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 12))
                        }
                        if shown.isEmpty {
                            Text(passwords.saved.isEmpty ? "No passwords yet." : "Nothing matches.")
                                .foregroundStyle(.secondary).padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .settingsCard()
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { i, login in
                                    if i > 0 { Divider() }
                                    LoginRow(login: login)
                                }
                            }
                            .settingsCard()
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct LoginRow: View {
    let login: Credential
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Favicon(url: nil, page: URL(string: login.origin), title: login.displayHost, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(login.displayHost).lineLimit(1)
                Text(login.username.isEmpty ? "No username" : login.username)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let source = login.source {
                Text(source).font(.system(size: 11)).foregroundStyle(.tertiary)
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
                Button("Delete", role: .destructive) { animate(Motion.swap) { browser.passwords.delete(login) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.primary.opacity(hovering ? 0.03 : 0))
        .onHover { hovering = $0 }
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
                Image(systemName: "key.fill").font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.tint)
            .help("Fill a saved password")
            .transition(Arrive(scale: 0.8))
        }
    }
}

// MARK: - Save offer

/// "Save password?" after you sign in somewhere new.
struct PasswordOfferCard: View {
    let offer: PasswordService.Offer
    @Environment(Browser.self) private var browser

    var body: some View {
        let login = offer.credential
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 15, weight: .medium)).foregroundStyle(.tint)
                Text(offer.isUpdate ? "Update the password for \(login.displayHost)?" : "Save the password for \(login.displayHost)?")
                    .font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
            }
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text(login.username.isEmpty ? "No username" : login.username).lineLimit(1)
                Spacer()
                Text(String(repeating: "•", count: min(12, max(6, login.password.count)))).foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .surface(.field, radius: 8)
            HStack {
                if !offer.isUpdate {
                    Button("Never for This Site") { browser.passwords.dismissOffer(never: true) }.buttonStyle(.glass)
                }
                Spacer()
                Button("Not Now") { browser.passwords.dismissOffer() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(offer.isUpdate ? "Update" : "Save") { browser.passwords.acceptOffer() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
    }
}
