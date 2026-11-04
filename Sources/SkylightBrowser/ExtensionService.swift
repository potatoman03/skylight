import AppKit
import Observation
import SkylightCore
import SkylightEngine
import SkylightKit

/// Chrome extensions: what's installed, their toolbar buttons, and their popups.
///
/// Extensions run in Chromium; this keeps the list (`extensions.json`), installs from the Chrome
/// Web Store or a folder, and hosts popups. Extensions run in the default profile, so Spaces on
/// other profiles don't get them.
@MainActor
@Observable
public final class ExtensionService {
    public struct Installed: Codable, Identifiable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable { case store, folder }

        public var id: String
        public var folder: URL
        public var source: Source
        public var enabled: Bool
        /// Shown in the toolbar; the rest live in the extensions menu.
        public var pinned: Bool
    }

    /// An open popup: the extension's page in a popover under its button.
    public struct Popup: Identifiable {
        public let id: String
        public let page: WebPage
        public var size: CGSize
    }

    public private(set) var installed: [Installed] = []
    public private(set) var manifests: [String: ExtensionManifest] = [:]
    public private(set) var popup: Popup?
    /// Extension ids being installed or loaded.
    public private(set) var busy: Set<String> = []
    public private(set) var lastError: String?
    public var isAvailable: Bool { host != nil }

    @ObservationIgnored private let host: ExtensionHost?
    @ObservationIgnored private let registryFile: URL
    @ObservationIgnored private let storeFolder: URL
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored var makePage: ((URL, WebPageDelegate) -> WebPage?)?
    @ObservationIgnored var openTab: ((URL) -> Void)?
    @ObservationIgnored var currentTabs: () -> (pages: [WebPage], active: WebPage?) = { ([], nil) }

    static let chromeVersion = "156.0.8078.80"
    static let popupMin = CGSize(width: 25, height: 25)
    static let popupMax = CGSize(width: 800, height: 600)

    init(host: ExtensionHost?, root: URL, toasts: ToastCenter) {
        self.host = host
        self.registryFile = root.appending(path: "extensions.json")
        self.storeFolder = root.appending(path: "Extensions", directoryHint: .isDirectory)
        self.toasts = toasts
        if let data = try? Data(contentsOf: registryFile), let list = try? JSONDecoder().decode([Installed].self, from: data) {
            installed = list
        }
        for ext in installed { manifests[ext.id] = try? ExtensionManifest.load(from: ext.folder) }
        host?.openTab = { [weak self] url in self?.openTab?(url) }
    }

    /// Loads every enabled extension, all at once.
    func start() async {
        guard host != nil else { return }
        await withTaskGroup(of: Void.self) { group in
            for ext in installed where ext.enabled { group.addTask { await self.load(ext) } }
        }
    }

    // MARK: - Lookup

    public var enabled: [Installed] { installed.filter(\.enabled) }
    public var toolbar: [Installed] { enabled.filter(\.pinned) }
    public var overflow: [Installed] { enabled.filter { !$0.pinned } }

    public func manifest(_ id: String) -> ExtensionManifest? { manifests[id] }

    public func icon(_ id: String, size: Int = 32) -> NSImage? {
        guard let ext = installed.first(where: { $0.id == id }), let path = manifests[id]?.icon(size: size) else { return nil }
        return NSImage(contentsOf: ext.folder.appending(path: path))
    }

    // MARK: - Installing

    /// Downloads an extension from the Chrome Web Store (a link or an id) and turns it on.
    public func install(fromStore input: String) async {
        guard let id = WebStore.extensionID(from: input) else {
            return fail("That isn't a Chrome Web Store link.")
        }
        if installed.contains(where: { $0.id == id }) { return toasts.show("Already installed", symbol: "puzzlepiece.extension") }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let (data, response) = try await URLSession.shared.data(from: WebStore.downloadURL(for: id, chromeVersion: Self.chromeVersion))
            if let http = response as? HTTPURLResponse, http.statusCode != 200 || data.isEmpty {
                throw CRXPackage.Failure.notCRX
            }
            let folder = storeFolder.appending(path: id, directoryHint: .isDirectory)
            try unpack(CRXPackage(data), into: folder)
            try await add(Installed(id: id, folder: folder, source: .store, enabled: true, pinned: true))
        } catch {
            fail("Couldn't install the extension: \(error.localizedDescription)")
        }
    }

    /// Adds an unpacked extension folder (for development, or one you built yourself).
    public func install(folder: URL) async {
        do {
            let manifest = try ExtensionManifest.load(from: folder)
            let provisional = manifest.key.flatMap(ExtensionID.from(manifestKey:)) ?? ExtensionID.from(path: folder.path)
            try await add(Installed(id: provisional, folder: folder, source: .folder, enabled: true, pinned: true))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func add(_ ext: Installed) async throws {
        var ext = ext
        manifests[ext.id] = try ExtensionManifest.load(from: ext.folder)
        if let host {
            busy.insert(ext.id)
            defer { busy.remove(ext.id) }
            let runtimeID = try await host.load(ext.folder)
            if runtimeID != ext.id {
                manifests[runtimeID] = manifests.removeValue(forKey: ext.id)
                ext.id = runtimeID
            }
        }
        installed.removeAll { $0.id == ext.id }
        installed.append(ext)
        save()
        toasts.show("Added \(manifests[ext.id]?.name ?? "the extension")", symbol: "puzzlepiece.extension")
    }

    private func unpack(_ package: CRXPackage, into folder: URL) throws {
        let fm = FileManager.default
        let zip = fm.temporaryDirectory.appending(path: "skylight-\(UUID().uuidString).zip")
        try package.archive.write(to: zip)
        defer { try? fm.removeItem(at: zip) }
        let staging = folder.deletingLastPathComponent().appending(path: ".\(folder.lastPathComponent)-new")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CRXPackage.Failure.notCRX }
        // The store id comes from the developer's key. Unpacked, Chromium would derive another
        // from the folder unless the manifest carries the key.
        let manifestFile = staging.appending(path: "manifest.json")
        if let key = package.publicKey, let data = try? Data(contentsOf: manifestFile),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["key"] == nil {
            object["key"] = key.base64EncodedString()
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: manifestFile)
        }
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: staging, to: folder)
    }

    // MARK: - Managing

    public func setEnabled(_ id: String, _ on: Bool) {
        guard let i = installed.firstIndex(where: { $0.id == id }), installed[i].enabled != on else { return }
        installed[i].enabled = on
        save()
        let ext = installed[i]
        if popup?.id == id { closePopup() }
        Task {
            if on { await load(ext) } else { try? await host?.unload(id) }
        }
    }

    public func setPinned(_ id: String, _ pinned: Bool) {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[i].pinned = pinned
        save()
    }

    /// Reorders the toolbar: `id` goes before `before` (or to the end).
    public func move(_ id: String, before: String?) {
        guard let from = installed.firstIndex(where: { $0.id == id }) else { return }
        let ext = installed.remove(at: from)
        let to = before.flatMap { b in installed.firstIndex { $0.id == b } } ?? installed.endIndex
        installed.insert(ext, at: to)
        save()
    }

    public func remove(_ id: String) {
        guard let ext = installed.first(where: { $0.id == id }) else { return }
        if popup?.id == id { closePopup() }
        installed.removeAll { $0.id == id }
        manifests[id] = nil
        save()
        Task { try? await host?.unload(id) }
        if ext.source == .store { try? FileManager.default.removeItem(at: ext.folder) }
    }

    /// Opens the extension's options page in a tab.
    public func openOptions(_ id: String) {
        guard let page = manifests[id]?.optionsPage, let url = URL(string: "chrome-extension://\(id)/\(page)") else { return }
        openTab?(url)
    }

    public func revealFolder(_ id: String) {
        guard let ext = installed.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ext.folder])
    }

    private func load(_ ext: Installed) async {
        guard let host else { return }
        busy.insert(ext.id)
        defer { busy.remove(ext.id) }
        do {
            let id = try await host.load(ext.folder)
            if id != ext.id, let i = installed.firstIndex(where: { $0.id == ext.id }) {
                installed[i].id = id
                manifests[id] = manifests.removeValue(forKey: ext.id)
                save()
            }
        } catch {
            fail("\(manifests[ext.id]?.name ?? "An extension") didn't load: \(error.localizedDescription)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: registryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(installed).write(to: registryFile, options: .atomic)
    }

    private func fail(_ message: String) {
        lastError = message
        toasts.show(message, symbol: "exclamationmark.triangle")
    }

    // MARK: - Toolbar buttons

    /// What clicking an extension's button does: its popup, or its `action.onClicked`.
    public func click(_ id: String) {
        if popup?.id == id { return closePopup() }
        closePopup()
        syncTabs()
        if let path = manifests[id]?.action?.popup, let url = URL(string: "chrome-extension://\(id)/\(path)"),
           let page = makePage?(url, self) {
            popup = Popup(id: id, page: page, size: CGSize(width: 320, height: 120))
        } else {
            Task {
                do { try await host?.triggerAction(id, page: currentTabs().active) } catch { fail(error.localizedDescription) }
            }
        }
    }

    public func closePopup() {
        guard let popup else { return }
        self.popup = nil
        popup.page.close()
    }

    /// Tells the extensions which pages exist and which is in front.
    public func syncTabs() {
        let tabs = currentTabs()
        host?.setTabs(tabs.pages, active: tabs.active)
    }

    /// Messages from extension pages (popups, options tabs) and their shim.
    func handle(_ message: JSONValue, from page: WebPage?) -> JSONValue {
        switch message["type"]?.stringValue {
        case "extensions.tabs":
            let tabs = currentTabs()
            let active = tabs.active.map(\.extensionTabID).flatMap { $0 == 0 ? nil : $0 }
            return ["active": active.map { .number(Double($0)) } ?? .null,
                    "all": .array(tabs.pages.map(\.extensionTabID).filter { $0 != 0 }.map { .number(Double($0)) })]
        case "extensions.openTab":
            if let url = message["url"]?.stringValue.flatMap(URL.init(string:)) {
                openTab?(url)
                if page === popup?.page { closePopup() }
            }
            return .null
        case "extensions.size":
            guard let page, page === popup?.page, let w = message["width"]?.doubleValue, let h = message["height"]?.doubleValue else { return .null }
            popup?.size = CGSize(width: min(max(w, Self.popupMin.width), Self.popupMax.width),
                                 height: min(max(h, Self.popupMin.height), Self.popupMax.height))
            return .null
        default:
            return .null
        }
    }
}

// MARK: - Popup pages

extension ExtensionService: WebPageDelegate {
    public func page(_ page: WebPage, didChange event: PageEvent) {}

    public func page(_ page: WebPage, wantsNewTab url: URL, inBackground: Bool) {
        openTab?(url)
        if !inBackground { closePopup() }
    }

    public func page(_ page: WebPage, didReceive message: JSONValue) async throws -> JSONValue {
        handle(message, from: page)
    }

    public func page(_ page: WebPage, requestsPermission request: PermissionRequest) { request.respond(false) }
    public func page(_ page: WebPage, requestsDialog request: DialogRequest) { request.respond(false, "") }
    public func page(_ page: WebPage, didFinishDownload fileURL: URL) {
        toasts.show("Downloaded \(fileURL.lastPathComponent)", symbol: "arrow.down.circle")
    }

    /// `window.close()` in a popup closes the popover.
    public func pageDidClose(_ page: WebPage) {
        if page === popup?.page { popup = nil }
    }
}
