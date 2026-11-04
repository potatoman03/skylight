import AppKit
import SkylightBrowser
import SkylightKit
import SwiftUI

// MARK: - Toolbar

/// Extension buttons, laid out for wherever the preferences put them.
struct ExtensionStrip: View {
    /// Icons inside the address bar are smaller than a toolbar row's.
    var compact = true
    @Environment(Browser.self) private var browser

    var body: some View {
        let service = browser.extensions
        let placement = browser.preferences.extensionPlacement
        let pinned = placement == .menu ? [] : service.toolbar
        if !service.enabled.isEmpty {
            HStack(spacing: compact ? 1 : 4) {
                ForEach(pinned) { ext in
                    ExtensionButton(ext: ext, compact: compact)
                        .transition(Arrive(scale: 0.8))
                }
                if placement == .menu || !service.overflow.isEmpty {
                    ExtensionsMenuButton(compact: compact)
                }
            }
            .motion(Motion.travel, value: pinned.map(\.id))
        }
    }
}

/// One extension's button. A click opens its popup under it.
private struct ExtensionButton: View {
    let ext: ExtensionService.Installed
    let compact: Bool
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let service = browser.extensions
        let manifest = service.manifest(ext.id)
        let open = service.popup?.id == ext.id
        Button { service.click(ext.id) } label: {
            ExtensionIcon(id: ext.id, size: compact ? 15 : 18)
                .frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
                .surface(open ? .selected : hovering ? .hover : nil, radius: compact ? 6 : 8)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(manifest?.title ?? "Extension")
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .popover(isPresented: popupBinding(open), arrowEdge: .bottom) { ExtensionPopupView() }
        .contextMenu { ExtensionMenu(ext: ext) }
        .draggable(ext.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != ext.id else { return false }
            animate(Motion.travel) { service.move(id, before: ext.id) }
            return true
        }
    }

    private func popupBinding(_ open: Bool) -> Binding<Bool> {
        Binding(get: { open }, set: { if !$0, browser.extensions.popup?.id == ext.id { browser.extensions.closePopup() } })
    }
}

/// The puzzle piece: every extension, with pins. Unpinned extensions open their popups here.
private struct ExtensionsMenuButton: View {
    let compact: Bool
    @Environment(Browser.self) private var browser
    @State private var listing = false
    @State private var hovering = false

    var body: some View {
        let service = browser.extensions
        let placement = browser.preferences.extensionPlacement
        // A popup of an extension without its own button opens here.
        let hosted = service.popup.map { popup in placement == .menu || !service.toolbar.contains { $0.id == popup.id } } ?? false
        Button { listing.toggle() } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: compact ? 11 : 13, weight: .medium))
                .frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
                .surface(listing || hosted ? .selected : hovering ? .hover : nil, radius: compact ? 6 : 8)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Extensions")
        .onHover { h in animate(Motion.feedback) { hovering = h } }
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
        VStack(alignment: .leading, spacing: 2) {
            Text("Extensions").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(service.enabled) { ext in
                ExtensionListRow(ext: ext, open: open)
            }
            Divider().padding(.vertical, 4)
            Button {
                browser.openSettings("extensions")
            } label: {
                Label("Manage Extensions…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
        .padding(10)
        .frame(width: 260)
    }
}

private struct ExtensionListRow: View {
    let ext: ExtensionService.Installed
    let open: (String) -> Void
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        let service = browser.extensions
        HStack(spacing: 9) {
            ExtensionIcon(id: ext.id, size: 16)
            Text(service.manifest(ext.id)?.name ?? ext.id).lineLimit(1)
            Spacer(minLength: 4)
            if browser.preferences.extensionPlacement != .menu {
                Button {
                    animate(Motion.travel) { service.setPinned(ext.id, !ext.pinned) }
                } label: {
                    Image(systemName: ext.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ext.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(ext.pinned ? "Unpin from the toolbar" : "Pin to the toolbar")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .surface(hovering ? .hover : nil, radius: 7)
        .contentShape(.rect)
        .onTapGesture { open(ext.id) }
        .onHover { h in animate(Motion.feedback) { hovering = h } }
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
        Button(ext.pinned ? "Unpin" : "Pin to Toolbar") { animate(Motion.travel) { service.setPinned(ext.id, !ext.pinned) } }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !service.isAvailable {
                    Label("Extensions need the full Skylight app. This build can't run them.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                SettingsBlock("Add", note: "Paste a Chrome Web Store link. Extensions run in your default profile, so Spaces on other profiles don't load them.") {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            TextField("chromewebstore.google.com/detail/…", text: $storeLink)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(installFromStore)
                            if !service.busy.isEmpty {
                                ProgressView().controlSize(.small)
                            }
                            Button("Add", action: installFromStore)
                                .disabled(WebStore.extensionID(from: storeLink) == nil || !service.busy.isEmpty)
                        }
                        .padding(12)
                        Divider()
                        SettingsRow("Unpacked folder", note: "An extension you're building, or one you downloaded and unzipped") {
                            Button("Choose…", action: chooseFolder)
                        }
                        Divider()
                        SettingsRow("Chrome Web Store") {
                            Button("Open") { browser.store.send(.openTab(URL(string: "https://chromewebstore.google.com/category/extensions")!)) }
                        }
                    }
                    .settingsCard()
                    .disabled(!service.isAvailable)
                }

                SettingsBlock("Installed") {
                    if service.installed.isEmpty {
                        Text("No extensions yet.").foregroundStyle(.secondary).padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading).settingsCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(service.installed.enumerated()), id: \.element.id) { i, ext in
                                if i > 0 { Divider() }
                                InstalledExtensionRow(ext: ext)
                            }
                        }
                        .settingsCard()
                    }
                }

                SettingsBlock("Toolbar", note: "Right-click a button for its options; drag buttons to reorder them.") {
                    VStack(spacing: 0) {
                        SettingsRow("Buttons") {
                            Picker("", selection: $prefs.extensionPlacement) {
                                ForEach(Preferences.ExtensionPlacement.allCases) { Text($0.name).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    .settingsCard()
                }
            }
            .padding(20)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ExtensionIcon(id: ext.id, size: 28).opacity(ext.enabled ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(manifest?.name ?? ext.id).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let version = manifest?.version, !version.isEmpty {
                            Text(version).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        if ext.source == .folder {
                            Text("Unpacked").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.primary.opacity(0.06), in: .capsule)
                        }
                    }
                    if let text = manifest?.description, !text.isEmpty {
                        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
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
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                Toggle("", isOn: Binding(get: { ext.enabled }, set: { service.setEnabled(ext.id, $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if let warnings = manifest?.warnings, !warnings.isEmpty {
                DisclosureGroup(isExpanded: $details) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(warnings, id: \.self) { Label($0, systemImage: "checkmark.shield").font(.system(size: 11.5)) }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                } label: {
                    Text("Can \(warnings[0].prefix(1).lowercased() + warnings[0].dropFirst())\(warnings.count > 1 ? " and more" : "")")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
