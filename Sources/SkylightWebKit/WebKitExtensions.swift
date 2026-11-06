import AppKit
import SkylightCore
import SkylightEngine
import WebKit

/// Chrome extensions, through WebKit's own web extension support. Each profile has a controller,
/// so its extensions keep their storage apart, and every profile runs every extension.
@MainActor
final class WebKitExtensionHost: NSObject, ExtensionHost {
    var openTab: (@MainActor (URL) -> Void)?
    var showPopup: (@MainActor (ExtensionPopup) -> Void)?
    var resizePopup: (@MainActor (CGSize) -> Void)?

    private var extensions: [String: WKWebExtension] = [:]
    private var controllers: [ObjectIdentifier: WKWebExtensionController] = [:]
    private var windows: [ObjectIdentifier: ExtensionWindow] = [:]

    func load(_ directory: URL, id: String) async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        extensions[id] = webExtension
        for controller in controllers.values { try add(webExtension, id: id, to: controller) }
    }

    func unload(_ id: String) async throws {
        extensions[id] = nil
        for controller in controllers.values {
            if let context = context(id, in: controller) { try controller.unload(context) }
        }
    }

    /// Extension workers live in the default data store, which nothing else in Skylight uses. Their
    /// addresses don't show up in its data records, so it's all of them or none. Those already
    /// running are stopped first and started again after.
    func forgetWorkers() async {
        let running = controllers.values.contains { !$0.extensionContexts.isEmpty }
        for controller in controllers.values {
            for context in controller.extensionContexts { try? controller.unload(context) }
        }
        // A worker takes a moment to stop, and starting one again before that fails.
        if running { try? await Task.sleep(for: .seconds(1)) }
        await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations],
                                                      modifiedSince: .distantPast)
        if running { try? await Task.sleep(for: .seconds(1)) }
        for controller in controllers.values {
            for (id, webExtension) in extensions { try? add(webExtension, id: id, to: controller) }
        }
    }

    func setTabs(_ groups: [ExtensionTabs]) {
        var seen: Set<ObjectIdentifier> = []
        for group in groups {
            guard let profile = group.profile as? WebKitProfile else { continue }
            let controller = controller(for: profile)
            seen.insert(ObjectIdentifier(controller))
            update(controller, pages: group.pages.compactMap { $0 as? WebKitPage }, active: group.active as? WebKitPage)
        }
        for controller in controllers.values where !seen.contains(ObjectIdentifier(controller)) {
            update(controller, pages: [], active: nil)
        }
    }

    /// WebKit drops what a content script sends from a tab it hasn't been told about, and nothing
    /// reports that, so a page has to be a tab before it starts loading.
    func open(_ page: WebKitPage, in profile: WebKitProfile) {
        let controller = controller(for: profile)
        guard let window = windows[ObjectIdentifier(controller)] else { return }
        update(controller, pages: window.pages + [page], active: window.active)
    }

    func triggerAction(_ id: String, page: SkylightEngine.WebPage?) async throws {
        guard let controller = (page as? WebKitPage)?.extensionController ?? controllers.values.first,
              let context = context(id, in: controller)
        else { throw WebEngineError.script("Open a page first.") }
        context.performAction(for: page as? WebKitPage)
    }

    func pageURL(_ id: String, path: String) -> URL? {
        URL(string: "webkit-extension://\(id)/\(path)")
    }

    func controller(for profile: WebKitProfile) -> WKWebExtensionController {
        if let controller = controllers[ObjectIdentifier(profile)] { return controller }
        let configuration = WKWebExtensionController.Configuration(identifier: profile.identifier)
        configuration.defaultWebsiteDataStore = profile.store
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        controllers[ObjectIdentifier(profile)] = controller
        let window = ExtensionWindow()
        windows[ObjectIdentifier(controller)] = window
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        for (id, webExtension) in extensions { try? add(webExtension, id: id, to: controller) }
        return controller
    }

    /// Stops the profile's extensions before its store goes away.
    func forget(_ profile: WebKitProfile) {
        guard let controller = controllers.removeValue(forKey: ObjectIdentifier(profile)) else { return }
        windows[ObjectIdentifier(controller)] = nil
        for context in controller.extensionContexts { try? controller.unload(context) }
    }

    /// What a page of one of these extensions must load with.
    func configuration(for url: URL, in controller: WKWebExtensionController) -> WKWebViewConfiguration? {
        controller.extensionContext(for: url)?.webViewConfiguration
    }

    private func add(_ webExtension: WKWebExtension, id: String, to controller: WKWebExtensionController) throws {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        // A stable address, so its pages and storage keep working from one launch to the next.
        if let base = pageURL(id, path: "") { context.baseURL = base }
        context.isInspectable = true
        // You saw and agreed to what it asks for when you added it.
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
    }

    private func context(_ id: String, in controller: WKWebExtensionController) -> WKWebExtensionContext? {
        controller.extensionContexts.first { $0.uniqueIdentifier == id }
    }

    private func update(_ controller: WKWebExtensionController, pages: [WebKitPage], active: WebKitPage?) {
        guard let window = windows[ObjectIdentifier(controller)] else { return }
        let before = window.pages
        let previous = window.active
        window.pages = pages
        window.active = active
        for page in pages where !before.contains(page) {
            page.extensionWindow = window
            page.extensionController = controller
            controller.didOpenTab(page)
        }
        for page in before where !pages.contains(page) {
            controller.didCloseTab(page, windowIsClosing: false)
        }
        if active !== previous, let active {
            controller.didActivateTab(active, previousActiveTab: previous)
        }
    }

    /// Popups don't report what size they want, so ask for as long as one is open.
    private func measure(_ webView: WKWebView) {
        let script = """
        (() => {
          const root = document.documentElement;
          if (!root || !document.body) return null;
          // Some popups, Proton Pass among them, copy the viewport into custom properties that set
          // their size. Measured as they stand, they only report the size they already have, and
          // shrink until nothing is left. What their style sheets ask for doesn't move.
          const own = [...root.style].filter((name) => name.startsWith('--'))
            .map((name) => [name, root.style.getPropertyValue(name)]);
          own.forEach(([name]) => root.style.removeProperty(name));
          const width = root.style.width;
          root.style.width = 'max-content';
          const w = Math.ceil(root.getBoundingClientRect().width);
          root.style.width = width;
          // Not the root's scrollHeight: it's never less than the viewport, so a popup couldn't shrink.
          const h = Math.ceil(Math.max(root.getBoundingClientRect().height, document.body.scrollHeight));
          own.forEach(([name, value]) => root.style.setProperty(name, value));
          return [w, h];
        })();
        """
        Task { [weak self, weak webView] in
            var last: CGSize?
            var attempts = 0
            while let webView, attempts < 5 || webView.window != nil {
                attempts += 1
                let size = await withCheckedContinuation { (done: CheckedContinuation<CGSize?, Never>) in
                    // The async form of this call is known to crash when a script returns null.
                    webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                        guard case let .success(value) = result, let size = value as? [Int], size.count == 2 else {
                            return done.resume(returning: nil)
                        }
                        done.resume(returning: CGSize(width: size[0], height: size[1]))
                    }
                }
                if let size, size != last {
                    last = size
                    self?.resizePopup?(size)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Optional access, which extensions ask for as they run.
    private func allows(_ what: String, for context: WKWebExtensionContext) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow “\(context.webExtension.displayName ?? "This extension")” to \(what)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension WebKitExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windows[ObjectIdentifier(controller)].map { [$0] } ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windows[ObjectIdentifier(controller)]
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        if let url = configuration.url { openTab?(url) }
        completionHandler(nil, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = context.optionsPageURL { openTab?(url) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        completionHandler(allows("use \(names)", for: context) ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", ")
        completionHandler(allows("read and change \(hosts)", for: context) ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let sites = patterns.map(\.string).sorted().joined(separator: ", ")
        completionHandler(allows("read and change \(sites)", for: context) ? patterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let webView = action.popupWebView else { return completionHandler(nil) }
        // WebKit lays a popup out at its content's size, whatever its view's frame. A popup that
        // reads its viewport before that settles keeps the tiny size it saw, so the viewport has
        // to follow the frame instead. Private, so a macOS without it only loses this.
        if webView.responds(to: NSSelectorFromString("_setSizeToContentAutoSizeMaximumSize:")) {
            webView.setValue(NSValue(size: .zero), forKey: "sizeToContentAutoSizeMaximumSize")
        }
        let action = MainThreadBox(value: action)
        showPopup?(ExtensionPopup(id: context.uniqueIdentifier, view: webView, close: { action.value.closePopup() }))
        measure(webView)
        completionHandler(nil)
    }
}

/// The one window each profile's extensions see. Skylight's Spaces are its tabs' real home.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    var pages: [WebKitPage] = []
    var active: WebKitPage?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { pages }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { active ?? pages.first }
}

extension WebKitPage: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { extensionWindow }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        extensionWindow?.pages.firstIndex(of: self) ?? NSNotFound
    }
}
