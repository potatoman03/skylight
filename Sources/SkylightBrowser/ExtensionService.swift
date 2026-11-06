import AppKit
import Observation
import SkylightCore
import SkylightEngine
import SkylightKit

/// Chrome extensions: what's installed, their toolbar buttons, and their popups.
///
/// Extensions run in Chromium; this keeps the list (`extensions.json`), installs from the Chrome
/// Web Store or a folder, and hosts popups. Every profile runs them, each with its own storage, so
/// signing in to one in a Space doesn't sign in the others. Chromium takes the list for all profiles
/// only at launch: one added while running reaches the default profile now and the rest next time.
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
        public let view: NSView
        let close: @MainActor () -> Void
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
    /// The copies extensions run from. See `ExtensionRuntime`.
    @ObservationIgnored private let runtimeFolder: URL
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored var openTab: ((URL) -> Void)?
    @ObservationIgnored var currentTabs: () -> (pages: [WebPage], active: WebPage?) = { ([], nil) }
    @ObservationIgnored var tabGroups: () -> [ExtensionTabs] = { [] }
    /// Whether the Space on screen uses the default profile, and whether any profile doesn't.
    /// Folders Chromium loaded at launch, in every profile.
    /// Added since launch, so only the default profile has them so far.

    static let chromeVersion = "156.0.8078.80"
    static let popupMin = CGSize(width: 25, height: 25)
    static let popupMax = CGSize(width: 800, height: 600)

    init(host: ExtensionHost?, root: URL, toasts: ToastCenter) {
        self.host = host
        self.registryFile = root.appending(path: "extensions.json")
        self.storeFolder = root.appending(path: "Extensions", directoryHint: .isDirectory)
        self.runtimeFolder = root.appending(path: "ExtensionRuntime", directoryHint: .isDirectory)
        self.toasts = toasts
        if let data = try? Data(contentsOf: registryFile), let list = try? JSONDecoder().decode([Installed].self, from: data) {
            installed = list
        }
        for ext in installed { manifests[ext.id] = try? ExtensionManifest.load(from: ext.folder) }
        host?.openTab = { [weak self] url in
            self?.closePopup()
            self?.openTab?(url)
        }
        host?.showPopup = { [weak self] popup in
            self?.popup = Popup(id: popup.id, view: popup.view, close: popup.close, size: CGSize(width: 320, height: 120))
        }
        host?.resizePopup = { [weak self] size in
            self?.popup?.size = CGSize(width: min(max(size.width, Self.popupMin.width), Self.popupMax.width),
                                       height: min(max(size.height, Self.popupMin.height), Self.popupMax.height))
        }
    }

    /// Loads every extension that's turned on.
    func start() async {
        await withTaskGroup(of: Void.self) { group in
            for ext in enabled { group.addTask { await self.load(ext) } }
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

    /// Downloads an extension from the Chrome Web Store (a link or an id) and turns it on. With
    /// `confirm`, you're shown what it can do and asked first: for installs a web page asked for.
    public func install(fromStore input: String, confirm: Bool = false, quietly: Bool = false) async {
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
            let staging = try stage(CRXPackage(data, expected: id), for: folder)
            if confirm {
                guard let manifest = try? ExtensionManifest.load(from: staging), await Self.askToAdd(manifest) else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
            }
            try replace(folder, with: staging)
            try await add(Installed(id: id, folder: folder, source: .store, enabled: true, pinned: true), quietly: quietly)
        } catch {
            if quietly { lastError = error.localizedDescription } else { fail("Couldn't install the extension: \(error.localizedDescription)") }
        }
    }

    /// Adds what you already use in another browser, fresh from the store: you chose these there,
    /// so there's no asking one by one. Their own settings and sign-ins stay with that browser.
    /// Returns how many were added.
    public func adopt(_ ids: [String]) async -> Int {
        guard isAvailable else { return 0 }
        var added = 0
        for id in ids where !installed.contains(where: { $0.id == id }) {
            let before = installed.count
            await install(fromStore: id, quietly: true)
            if installed.count > before { added += 1 }
        }
        return added
    }

    /// The extension's name and what it can do, with Add and Cancel. For an update, only what
    /// it can newly do.
    private static func askToAdd(_ manifest: ExtensionManifest, newWarnings: [String]? = nil) async -> Bool {
        let alert = NSAlert()
        let warnings = newWarnings ?? manifest.warnings
        if newWarnings != nil {
            alert.messageText = "Update “\(manifest.name)” to version \(manifest.version)?"
            alert.informativeText = "The update asks for more access. It could also:\n" + warnings.map { "• \($0)" }.joined(separator: "\n")
            alert.addButton(withTitle: "Update")
        } else {
            alert.messageText = "Add “\(manifest.name)” to Skylight?"
            alert.informativeText = warnings.isEmpty
                ? "It doesn't ask for any special access."
                : "It can:\n" + warnings.map { "• \($0)" }.joined(separator: "\n")
            alert.addButton(withTitle: "Add Extension")
        }
        alert.addButton(withTitle: "Cancel")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
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

    private func add(_ ext: Installed, quietly: Bool = false) async throws {
        var ext = ext
        manifests[ext.id] = try ExtensionManifest.load(from: ext.folder)
        if let host {
            busy.insert(ext.id)
            defer { busy.remove(ext.id) }
            try await run(ext, on: host)
        }
        installed.removeAll { $0.id == ext.id }
        installed.append(ext)
        save()
        let name = manifests[ext.id]?.name ?? "the extension"
        if quietly { return }
        toasts.show("Added \(name)", symbol: "puzzlepiece.extension")
    }

    /// Unzips a package beside `folder`, to look at before `replace(_:with:)` moves it in.
    private func stage(_ package: CRXPackage, for folder: URL) throws -> URL {
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
        if let data = try? Data(contentsOf: manifestFile),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["key"] == nil {
            object["key"] = package.publicKey.base64EncodedString()
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: manifestFile)
        }
        return staging
    }

    private func replace(_ folder: URL, with staging: URL) throws {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: staging, to: folder)
    }

    // MARK: - Updating

    /// Updates that ask for more access than the version you have, waiting for your OK: id to the
    /// version on offer.
    public private(set) var updatesToApprove: [String: String] = [:]

    /// Checks the store for updates now and then, as Chrome does every five hours.
    func keepUpdated() async {
        while !Task.isCancelled {
            await checkForUpdates()
            try? await Task.sleep(for: .seconds(5 * 60 * 60))
        }
    }

    /// Installs newer versions of extensions from the store. An update that asks for more access
    /// waits in `updatesToApprove`.
    func checkForUpdates() async {
        let versions = Dictionary(installed.filter { $0.source == .store }.compactMap { ext in
            manifests[ext.id].map { (ext.id, $0.version) }
        }, uniquingKeysWith: { a, _ in a })
        guard host != nil, !versions.isEmpty,
              let (data, _) = try? await URLSession.shared.data(from: WebStore.updateCheckURL(for: versions, chromeVersion: Self.chromeVersion))
        else { return }
        for (id, version) in WebStore.availableVersions(in: data) {
            guard let current = versions[id], WebStore.isVersion(version, laterThan: current), updatesToApprove[id] == nil else { continue }
            await update(id, approved: false)
        }
    }

    /// Asks before installing an update that wants more access.
    public func approveUpdate(_ id: String) async {
        await update(id, approved: true)
    }

    private func update(_ id: String, approved: Bool) async {
        guard let ext = installed.first(where: { $0.id == id && $0.source == .store }), let old = manifests[id], !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let (data, response) = try await URLSession.shared.data(from: WebStore.downloadURL(for: id, chromeVersion: Self.chromeVersion))
            if let http = response as? HTTPURLResponse, http.statusCode != 200 || data.isEmpty { throw CRXPackage.Failure.notCRX }
            let staging = try stage(CRXPackage(data, expected: id), for: ext.folder)
            let new = try ExtensionManifest.load(from: staging)
            guard WebStore.isVersion(new.version, laterThan: old.version) else {
                try? FileManager.default.removeItem(at: staging)
                updatesToApprove[id] = nil
                return
            }
            let added = new.addedWarnings(since: old)
            if !added.isEmpty {
                guard approved else {
                    try? FileManager.default.removeItem(at: staging)
                    updatesToApprove[id] = new.version
                    return
                }
                guard await Self.askToAdd(new, newWarnings: added) else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
            }
            updatesToApprove[id] = nil
            if popup?.id == id { closePopup() }
            if ext.enabled { try? await host?.unload(id) }
            try replace(ext.folder, with: staging)
            manifests[id] = new
            if ext.enabled, let host { try await run(ext, on: host) }
        } catch {
            fail("Couldn't update \(old.name): \(error.localizedDescription)")
        }
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
        let runtimeFolder = runtimeFolder
        Task {
            try? await host?.unload(id)
            ExtensionRuntime.discard(id: id, in: runtimeFolder)
        }
        if ext.source == .store { try? FileManager.default.removeItem(at: ext.folder) }
    }

    /// Opens the extension's options page in a tab.
    public func openOptions(_ id: String) {
        guard let page = manifests[id]?.optionsPage, let url = host?.pageURL(id, path: page) else { return }
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
            try await run(ext, on: host)
        } catch {
            fail("\(manifests[ext.id]?.name ?? "An extension") didn't load: \(error.localizedDescription)")
        }
    }

    private func run(_ ext: Installed, on host: ExtensionHost) async throws {
        let (folder, id, root) = (ext.folder, ext.id, runtimeFolder)
        let prepared = try await Task.detached { try ExtensionRuntime.prepare(folder, id: id, in: root) }.value
        if prepared.workerChanged { await host.forgetWorkers() }
        try await host.load(prepared.folder, id: id)
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
        Task {
            do { try await host?.triggerAction(id, page: currentTabs().active) } catch { fail(error.localizedDescription) }
        }
    }

    public func closePopup() {
        guard let popup else { return }
        self.popup = nil
        popup.close()
    }

    /// Tells the extensions which pages exist and which is in front.
    public func syncTabs() {
        host?.setTabs(tabGroups())
    }

        /// The Chrome Web Store page's own button, which `storePageScript` takes over: whether its
    /// extension is in, and adding it.
    ///
    /// Any page can post this, so the extension is the one the tab is really showing, by the
    /// address Skylight knows rather than the page's word, and adding it asks you first.
    func handleStore(_ message: JSONValue, tabURL: URL?) async -> JSONValue {
        guard isAvailable, let tabURL, tabURL.scheme == "https", tabURL.host() == "chromewebstore.google.com",
              let id = WebStore.extensionID(from: tabURL.absoluteString) else { return "unavailable" }
        if message["type"]?.stringValue == "extensions.storeInstall", !installed.contains(where: { $0.id == id }), !busy.contains(id) {
            await install(fromStore: id, confirm: true)
        }
        return installed.contains { $0.id == id } ? "added" : busy.contains(id) ? "adding" : "add"
    }

    /// On the Chrome Web Store, its Add to Chrome button (which only works in Chrome) becomes Add
    /// to Skylight, and the prompts to switch to Chrome go away.
    public static let storePageScript = """
    (() => {
      if (location.hostname !== 'chromewebstore.google.com' || !window.__skylight || window.__skylightStore) return;
      Object.defineProperty(window, '__skylightStore', { value: true });
      const labels = { add: 'Add to Skylight', adding: 'Adding…', added: 'Added to Skylight' };
      const theirs = /^(Add to Chrome|Remove from Chrome)$/;
      const post = (type) => window.__skylight.post({ type, url: location.href }).catch(() => 'unavailable');
      let state = null, page = '', dismissed = false;

      // Puts `text` in the button's first piece of text, leaving its icon and styling be.
      const relabel = (button, text) => {
        const walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        let first = null, node;
        while ((node = walker.nextNode())) {
          if (!node.nodeValue.trim()) continue;
          if (!first) first = node; else node.nodeValue = '';
        }
        if (first && first.nodeValue !== text) first.nodeValue = text;
      };
      const apply = () => {
        if (!labels[state]) return;
        for (const button of document.querySelectorAll('button')) {
          if (!button.dataset.skylight && !theirs.test(button.textContent.trim())) continue;
          button.dataset.skylight = '1';
          relabel(button, labels[state]);
          const off = state !== 'add';
          button.disabled = false;
          button.removeAttribute('aria-disabled');
          button.style.opacity = off ? '0.6' : '';
          button.style.pointerEvents = 'auto';
        }
      };
      // The "Switch to Chrome" dialog and banner.
      const quiet = () => {
        if (!dismissed) {
          for (const button of document.querySelectorAll('button, [role=button]')) {
            if (button.textContent.trim() !== 'No thanks') continue;
            const box = button.closest('[role=dialog], [role=alertdialog]') || button.parentElement?.parentElement?.parentElement;
            if (box && /Switch to Chrome/.test(box.textContent)) { button.click(); dismissed = true; }
          }
        }
        const walker = document.createTreeWalker(document.body || document, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          if (!/^Switch to Chrome to install/.test(node.nodeValue.trim())) continue;
          let box = node.parentElement;
          while (box.parentElement && box.parentElement !== document.body && box.parentElement.textContent.trim().length < 160) box = box.parentElement;
          box.style.display = 'none';
        }
      };
      const update = () => {
        scheduled = false;
        quiet();
        if (!/^\\/detail\\//.test(location.pathname)) return;
        if (location.href !== page) {
          page = location.href;
          state = null;
          document.querySelectorAll('button[data-skylight]').forEach((b) => delete b.dataset.skylight);
          post('extensions.storeStatus').then((s) => { state = s; apply(); });
        }
        apply();
      };
      let scheduled = false;
      const schedule = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(update); } };
      new MutationObserver(schedule).observe(document, { childList: true, subtree: true, characterData: true });
      document.addEventListener('click', (event) => {
        const button = event.target instanceof Element && event.target.closest('button[data-skylight]');
        if (!button || !labels[state]) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (state !== 'add') return;
        state = 'adding';
        apply();
        post('extensions.storeInstall').then((s) => { state = s; apply(); });
      }, true);
      schedule();
    })();
    """
}
