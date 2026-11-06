import SkylightBrowser
import SkylightCore
import SkylightKit
import SwiftUI

/// Fills the page with a saved address or card, chosen here. Nothing fills without this menu.
struct AutofillButton: View {
    let url: URL?
    @Environment(Browser.self) private var browser

    var body: some View {
        let state = browser.store.state
        let data = browser.autofill.data(in: state.passwordProfile(for: state.activeSpace.profileID))
        if !data.isEmpty, url?.scheme == "https" || url?.scheme == "http" {
            Menu {
                if !data.addresses.isEmpty {
                    Section("Fill an address") {
                        ForEach(data.addresses) { address in
                            Button(address.title) { browser.fillAddress(address) }
                        }
                    }
                }
                if !data.cards.isEmpty {
                    Section("Fill a card") {
                        ForEach(data.cards) { card in
                            Button(card.name.isEmpty ? card.title : "\(card.name) \(card.title)") {
                                Task { await browser.fillCard(card) }
                            }
                        }
                    }
                }
                Divider()
                Button("Manage Addresses and Cards…") { browser.openSettings("passwords") }
            } label: {
                Image(systemName: "person.text.rectangle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Fill an address or card")
        }
    }
}

/// Settings › Passwords: what's saved for forms, to look at or remove.
struct AutofillSection: View {
    let profile: ProfileID
    @Environment(Browser.self) private var browser

    var body: some View {
        let data = browser.autofill.data(in: profile)
        Section("Addresses and Cards") {
            if data.isEmpty {
                Text("Import from another browser to bring yours over.").foregroundStyle(.secondary)
            }
            ForEach(data.addresses) { address in
                row(address.title, [address.line1, address.city, address.zip].filter { !$0.isEmpty }.joined(separator: ", ")) {
                    browser.autofill.remove(address: address, from: profile)
                }
            }
            ForEach(data.cards) { card in
                row(card.title, [card.name, String(format: "%02d/%d", card.month, card.year)].filter { !$0.isEmpty }.joined(separator: " · ")) {
                    browser.autofill.remove(card: card, from: profile)
                }
            }
        }
    }

    private func row(_ title: String, _ detail: String, remove: @escaping () -> Void) -> some View {
        LabeledContent {
            Button("Remove", role: .destructive, action: remove).buttonStyle(.borderless)
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// Where you've been in this Space's profile: search it, reopen a page, or clear it.
struct HistorySheet: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var entries: [HistoryEntry] = []
    @State private var confirming = false

    private var profile: ProfileID { browser.store.state.activeSpace.profileID }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.title2.weight(.semibold))
                Spacer()
                TextField("Search", text: $search, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 220)
            }
            .padding(20)
            List(entries) { entry in
                Button {
                    browser.store.send(.openTab(entry.url))
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayTitle).lineLimit(1)
                        Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove from History") {
                        browser.history.remove(entry.url, from: profile)
                        load()
                    }
                }
            }
            .overlay { if entries.isEmpty { Text(search.isEmpty ? "Nothing yet." : "Nothing matches.").foregroundStyle(.secondary) } }
            HStack {
                Button("Clear History…", role: .destructive) { confirming = true }.disabled(entries.isEmpty && search.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .onAppear(perform: load)
        .onChange(of: search) { load() }
        .alert("Clear all history for this profile?", isPresented: $confirming) {
            Button("Clear History", role: .destructive) {
                browser.history.clear(profile)
                load()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func load() { entries = browser.history.recent(in: profile, matching: search) }
}
