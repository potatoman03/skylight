import AppKit
import SkylightBrowser
import SkylightKit
import SwiftUI

// MARK: - Toolbar

/// Pinned extensions' buttons, for the toolbar.
struct PinnedExtensionButtons: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 2) {
            ForEach(browser.extensions.toolbar) { ext in
                ExtensionButton(ext: ext)
            }
        }
    }
}

/// One extension's button. A click opens its popup under it.
private struct ExtensionButton: View {
    let ext: ExtensionService.Installed
    @Environment(Browser.self) private var browser

    var body: some View {
        let service = browser.extensions
        let manifest = service.manifest(ext.id)
        let open = service.popup?.id == ext.id
        Button { service.click(ext.id) } label: {
            ExtensionIcon(id: ext.id, size: 16)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(manifest?.title ?? "Extension")
        .popover(isPresented: Binding(get: { open }, set: { if !$0, service.popup?.id == ext.id { service.closePopup() } }),
                 arrowEdge: .bottom) { ExtensionPopupView() }
        .contextMenu { ExtensionMenu(ext: ext) }
    }
}

/// The puzzle piece: every extension, with pins. Unpinned extensions open their popups here.
struct ExtensionsMenuButton: View {
    @Environment(Browser.self) private var browser
    @State private var listing = false

    var body: some View {
        let service = browser.extensions
        let showsButtons = browser.preferences.extensionPlacement.showsButtons
        // A popup of an extension without its own button opens here.
        let hosted = service.popup.map { popup in !showsButtons || !service.toolbar.contains { $0.id == popup.id } } ?? false
        Button { listing.toggle() } label: {
            Label("Extensions", systemImage: "puzzlepiece.extension")
        }
        .help("Extensions")
        .popover(isPresented: Binding(get: { listing || hosted }, set: { shown in
            if !shown {
                listing = false
                if hosted { service.closePopup() }
            }
        }), arrowEdge: .bottom) {
            if hosted {
                ExtensionPopupView()
            } else {
                ExtensionList { id in
                    listing = false
                    service.click(id)
                }
            }
        }
    }
}

/// Every enabled extension, as a list in the puzzle popover.
private struct ExtensionList: View {
    let open: (String) -> Void
    @Environment(Browser.self) private var browser

    var body: some View {
        let service = browser.extensions
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Extensions") {
                    if service.enabled.isEmpty {
                        Text("No extensions turned on").foregroundStyle(.secondary)
                    }
                    ForEach(service.enabled) { ext in
                        ExtensionListRow(ext: ext, open: open)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(max(service.enabled.count, 1)) * 32 + 40, 360))
            Divider()
            Button("Manage Extensions…") { browser.openSettings("extensions") }
                .buttonStyle(.borderless)
                .padding(12)
        }
        .frame(width: 280)
    }
}

private struct ExtensionListRow: View {
    let ext: ExtensionService.Installed
    let open: (String) -> Void
    @Environment(Browser.self) private var browser

    var body: some View {
        let service = browser.extensions
        HStack {
            Button { open(ext.id) } label: {
                Label {
                    Text(service.manifest(ext.id)?.name ?? ext.id).lineLimit(1)
                } icon: {
                    ExtensionIcon(id: ext.id, size: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if browser.preferences.extensionPlacement.showsButtons {
                Button {
                    service.setPinned(ext.id, !ext.pinned)
                } label: {
                    Image(systemName: ext.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(ext.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help(ext.pinned ? "Unpin from the toolbar" : "Pin to the toolbar")
            }
        }
        .contextMenu { ExtensionMenu(ext: ext) }
    }
}

struct ExtensionMenu: View {
    let ext: ExtensionService.Installed
    @Environment(Browser.self) private var browser

    var body: some View {
        let service = browser.extensions
        let manifest = service.manifest(ext.id)
        Text(manifest?.name ?? ext.id)
        if manifest?.optionsPage != nil {
            Button("Options") { service.openOptions(ext.id) }
        }
        Button(ext.pinned ? "Unpin" : "Pin to Toolbar") { service.setPinned(ext.id, !ext.pinned) }
        Button("Manage Extensions…") { browser.openSettings("extensions") }
        Divider()
        Button("Turn Off") { service.setEnabled(ext.id, false) }
        Button("Remove", role: .destructive) { animate(Motion.travel) { service.remove(ext.id) } }
    }
}

struct ExtensionIcon: View {
    let id: String
    var size: CGFloat = 16
    @Environment(Browser.self) private var browser

    var body: some View {
        if let image = browser.extensions.icon(id, size: Int(size * 2)) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Popup

/// The open popup's page, at the size its content asks for (Chrome's limits: 25–800 × 25–600).
struct ExtensionPopupView: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        if let popup = browser.extensions.popup {
            HostedPageView(view: popup.page.view)
                .frame(width: popup.size.width, height: popup.size.height)
                .animation(Motion.travel, value: popup.size)
        }
    }
}

/// Shows a view that something else owns (an engine page) without taking it over.
struct HostedPageView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

// MARK: - Settings › Extensions

struct ExtensionSettings: View {
    @Environment(Browser.self) private var browser
    @State private var storeLink = ""

    var body: some View {
        @Bindable var prefs = browser.preferences
        let service = browser.extensions
        Form {
            if !service.isAvailable {
                Label("Extensions need the full Skylight app. This build can't run them.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Section {
                if service.installed.isEmpty {
                    Text("No extensions yet.").foregroundStyle(.secondary)
                }
                ForEach(service.installed) { ext in
                    InstalledExtensionRow(ext: ext)
                }
            } header: {
                Text("Installed")
            }

            Section {
                HStack {
                    TextField("Chrome Web Store link", text: $storeLink, prompt: Text("chromewebstore.google.com/detail/…"))
                        .onSubmit(installFromStore)
                    if !service.busy.isEmpty { ProgressView().controlSize(.small) }
                    Button("Add", action: installFromStore)
                        .disabled(WebStore.extensionID(from: storeLink) == nil || !service.busy.isEmpty)
                }
                LabeledContent {
                    Button("Choose…", action: chooseFolder)
                } label: {
                    Text("Unpacked folder")
                    Text("An extension you're building, or one you downloaded and unzipped")
                }
                LabeledContent("Chrome Web Store") {
                    Button("Open") { browser.store.send(.openTab(URL(string: "https://chromewebstore.google.com/category/extensions")!)) }
                }
            } header: {
                Text("Add")
            } footer: {
                Text("Extensions run in your default profile, so Spaces on other profiles don't load them.")
            }
            .disabled(!service.isAvailable)

            Section {
                Picker("Show", selection: $prefs.extensionPlacement) {
                    ForEach(Preferences.ExtensionPlacement.choices) { Text($0.name).tag($0) }
                }
            } header: {
                Text("Toolbar")
            } footer: {
                Text("Pin extensions from the Extensions menu in the toolbar. Right-click a button for its options.")
            }
        }
        .formStyle(.grouped)
    }

    private func installFromStore() {
        let link = storeLink
        guard WebStore.extensionID(from: link) != nil else { return }
        storeLink = ""
        Task { await browser.extensions.install(fromStore: link) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Extension"
        panel.message = "Choose a folder with a manifest.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await browser.extensions.install(folder: url) }
    }
}

private struct InstalledExtensionRow: View {
    let ext: ExtensionService.Installed
    @Environment(Browser.self) private var browser
    @State private var details = false

    var body: some View {
        let service = browser.extensions
        let manifest = service.manifest(ext.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ExtensionIcon(id: ext.id, size: 28).opacity(ext.enabled ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(manifest?.name ?? ext.id).lineLimit(1)
                        if let version = manifest?.version, !version.isEmpty {
                            Text(version).font(.caption).foregroundStyle(.tertiary)
                        }
                        if ext.source == .folder {
                            Text("Unpacked").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let text = manifest?.description, !text.isEmpty {
                        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if service.busy.contains(ext.id) { ProgressView().controlSize(.small) }
                Menu {
                    ExtensionMenu(ext: ext)
                    Button("Show in Finder") { service.revealFolder(ext.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Toggle("Enabled", isOn: Binding(get: { ext.enabled }, set: { service.setEnabled(ext.id, $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if let warnings = manifest?.warnings, !warnings.isEmpty {
                DisclosureGroup(isExpanded: $details) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(warnings, id: \.self) { Label($0, systemImage: "checkmark.shield").font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                } label: {
                    Text("Can \(warnings[0].prefix(1).lowercased() + warnings[0].dropFirst())\(warnings.count > 1 ? " and more" : "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 38)
            }
        }
    }
}
