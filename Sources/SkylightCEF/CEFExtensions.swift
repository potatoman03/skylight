import CEFBridge
import Foundation
import SkylightCore
import SkylightEngine

/// The DevTools protocol over the engine's private pipe (see `SKEngine.sendDevToolsMessage`).
@MainActor
final class DevToolsChannel {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Protocol events: method, params and the session they came from (nil for the browser).
    var onEvent: (@MainActor (String, JSONValue, String?) -> Void)?

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    init() {
        SKEngine.setDevToolsMessageHandler { [weak self] text in
            MainActor.assumeIsolated { self?.receive(text) }
        }
    }

    @discardableResult
    func send(_ method: String, _ params: JSONValue = [:], session: String? = nil) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method), "params": params]
        if let session { message["sessionId"] = .string(session) }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            SKEngine.sendDevToolsMessage(JSONValue.object(message).serialized())
        }
    }

    private func receive(_ text: String) {
        guard let message = try? JSONValue.parse(text) else { return }
        if let id = message["id"]?.intValue {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: Failure(message: error["message"]?.stringValue ?? "DevTools error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        } else if let method = message["method"]?.stringValue {
            onEvent?(method, message["params"] ?? .null, message["sessionId"]?.stringValue)
        }
    }
}

/// Chrome extensions on Alloy pages.
///
/// Alloy pages aren't in a Chrome tab strip, so `chrome.tabs.query({active: true})` finds nothing
/// and `chrome.tabs.create` has no window to open in. A small shim, run in every extension's
/// service worker and pages, answers those calls with Skylight's own tabs and opens new tabs
/// through Skylight.
@MainActor
final class CEFExtensionHost: ExtensionHost {
    var openTab: (@MainActor (URL) -> Void)?

    private let channel = DevToolsChannel()
    private var started = false
    /// Running extension service workers: target id to browser context, which is Chromium's name
    /// for a profile.
    private var workers: [String: String] = [:]
    /// What each profile's extensions may see. Tab ids never cross from one profile to another.
    private var tabs: [String: TabsSnapshot] = [:]
    private var groups: [ExtensionTabs] = []
    /// Browser contexts, by profile.
    private var contexts: [ObjectIdentifier: String] = [:]
    private var pushTask: Task<Void, Never>?
    /// One marker search at a time: a second one would overwrite the first one's marker.
    private var search: Task<(id: String, context: String)?, Never>?

    struct TabsSnapshot: Equatable {
        static let none = TabsSnapshot(active: nil, all: [])

        var active: Int?
        var all: [Int]

        var json: JSONValue {
            ["active": active.map { .number(Double($0)) } ?? .null, "all": .array(all.map { .number(Double($0)) })]
        }
    }

    init() {
        channel.onEvent = { [weak self] method, params, session in self?.handle(method, params, session: session) }
        SKEngine.setForeignBrowserHandler { [weak self] browser, url in
            MainActor.assumeIsolated { self?.adopt(browser, url: url) }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        // Every extension service worker that starts gets the shim before its own code runs.
        _ = try? await channel.send("Target.setAutoAttach", [
            "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
            "filter": [["type": "service_worker"], ["exclude": true]],
        ])
        _ = try? await channel.send("Target.setDiscoverTargets", [
            "discover": true, "filter": [["type": "service_worker"], ["exclude": true]],
        ])
    }

    /// Chrome's tab ids for Alloy pages aren't CEF's browser ids, and nothing native reports
    /// them. A built-in extension asks: its content script learns the tab's id from its
    /// service worker and marks the page, and the page tells Skylight (see `CEFEngine`).
    static func writeHelper(to folder: URL) {
        let files = [
            "manifest.json": #"{"manifest_version":3,"name":"Skylight Tabs","version":"1.0","description":"Tells Skylight each page's tab id.","background":{"service_worker":"sw.js"},"content_scripts":[{"matches":["<all_urls>"],"js":["cs.js"],"run_at":"document_start"}]}"#,
            "sw.js": "chrome.runtime.onMessage.addListener((m, sender, reply) => { if (m === 'skylight.tab') reply(sender.tab ? sender.tab.id : null); });",
            "cs.js": "chrome.runtime.sendMessage('skylight.tab', (id) => { if (id != null) document.documentElement.setAttribute('data-skylight-tab', String(id)); });",
        ]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try? Data(text.utf8).write(to: folder.appending(path: name), options: .atomic) }
    }

    func load(_ directory: URL) async throws -> String {
        guard SKEngine.hasDevToolsPipe() else { throw DevToolsChannel.Failure(message: "Extensions aren't available in this build.") }
        await start()
        let result = try await channel.send("Extensions.loadUnpacked", ["path": .string(directory.path)])
        guard let id = result["id"]?.stringValue else { throw DevToolsChannel.Failure(message: "Chromium didn't load the extension.") }
        return id
    }

    func unload(_ id: String) async throws {
        try await channel.send("Extensions.uninstall", ["id": .string(id)])
    }

    func setTabs(_ groups: [ExtensionTabs]) {
        self.groups = groups
        // Coalesce quick tab switches into one update per worker.
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await self.pushTabs()
        }
    }

    private func pushTabs() async {
        guard !workers.isEmpty else { return }
        for group in groups where contexts[ObjectIdentifier(group.profile)] == nil {
            if let page = group.pages.first, let target = await target(for: page) {
                contexts[ObjectIdentifier(group.profile)] = target.context
            }
        }
        var next: [String: TabsSnapshot] = [:]
        for group in groups {
            guard let context = contexts[ObjectIdentifier(group.profile)] else { continue }
            next[context] = TabsSnapshot(active: group.active.map(\.extensionTabID).flatMap { $0 == 0 ? nil : $0 },
                                         all: group.pages.map(\.extensionTabID).filter { $0 != 0 })
        }
        let old = tabs
        tabs = next
        for (target, context) in workers where old[context] != next[context] { await update(worker: target) }
    }

    func triggerAction(_ id: String, page: WebPage?) async throws {
        await start()
        guard let target = await target(for: page) else {
            throw DevToolsChannel.Failure(message: "Open a page first.")
        }
        try await channel.send("Extensions.triggerAction", ["id": .string(id), "targetId": .string(target.id)])
    }

    // MARK: - Service workers

    private func handle(_ method: String, _ params: JSONValue, session: String?) {
        let info = params["targetInfo"]
        switch method {
        case "Target.attachedToTarget":
            // Sessions Skylight opened itself aren't waiting, and are still in use.
            guard let sessionID = params["sessionId"]?.stringValue, params["waitingForDebugger"]?.boolValue == true else { return }
            let isExtension = info?["url"]?.stringValue?.hasPrefix("chrome-extension://") == true
            let context = info?["browserContextId"]?.stringValue
            Task { await self.prepare(session: sessionID, inject: isExtension, context: context) }
        case "Target.targetCreated", "Target.targetInfoChanged":
            if let id = info?["targetId"]?.stringValue, let context = info?["browserContextId"]?.stringValue,
               info?["url"]?.stringValue?.hasPrefix("chrome-extension://") == true, workers[id] == nil {
                workers[id] = context
                // Extensions Chromium loaded at launch start before the shim can get in first.
                Task {
                    await self.pushTabs()
                    await self.update(worker: id)
                }
            }
        case "Target.targetDestroyed":
            if let id = params["targetId"]?.stringValue { workers[id] = nil }
        default:
            break
        }
    }

    /// A worker paused at start: add the shim, let it run, and let go of it so it can sleep.
    private func prepare(session: String, inject: Bool, context: String?) async {
        // Read the tabs at each step: they can change while this waits.
        let script = { Self.workerScript(context.flatMap { self.tabs[$0] } ?? .none) }
        if inject {
            _ = try? await channel.send("Runtime.evaluate", ["expression": .string(script())], session: session)
        }
        _ = try? await channel.send("Runtime.runIfWaitingForDebugger", session: session)
        if inject {
            // Code that waited for the shim's first run sees it now.
            _ = try? await channel.send("Runtime.evaluate", ["expression": .string(script())], session: session)
        }
        _ = try? await channel.send("Target.detachFromTarget", ["sessionId": .string(session)])
    }

    private func update(worker target: String) async {
        guard let attached = try? await channel.send("Target.attachToTarget", ["targetId": .string(target), "flatten": true]),
              let session = attached["sessionId"]?.stringValue else { workers[target] = nil; return }
        let snapshot = workers[target].flatMap { tabs[$0] } ?? .none
        _ = try? await channel.send("Runtime.evaluate", ["expression": .string(Self.workerScript(snapshot))], session: session)
        _ = try? await channel.send("Target.detachFromTarget", ["sessionId": .string(session)])
    }

    /// The page's DevTools target and its browser context. Pages with the same address are told
    /// apart by a marker.
    private func target(for page: WebPage?) async -> (id: String, context: String)? {
        guard let page else { return nil }
        let previous = search
        let next = Task { () -> (id: String, context: String)? in
            await previous?.value
            return await self.find(page)
        }
        search = next
        return await next.value
    }

    private func find(_ page: WebPage) async -> (id: String, context: String)? {
        // Without its own filter, this reuses the one for service workers.
        let pagesOnly: JSONValue = ["filter": [["type": "page"], ["exclude": true]]]
        guard let targets = try? await channel.send("Target.getTargets", pagesOnly)["targetInfos"]?.arrayValue else { return nil }
        let marker = UUID().uuidString
        _ = try? await page.evaluate("window.__skylightTarget = \(JSONValue.jsLiteral(marker))")
        for info in targets {
            guard let id = info["targetId"]?.stringValue, let context = info["browserContextId"]?.stringValue,
                  let attached = try? await channel.send("Target.attachToTarget", ["targetId": .string(id), "flatten": true]),
                  let session = attached["sessionId"]?.stringValue else { continue }
            let found = try? await channel.send("Runtime.evaluate", ["expression": "window.__skylightTarget", "returnByValue": true],
                                                session: session)
            _ = try? await channel.send("Target.detachFromTarget", ["sessionId": .string(session)])
            if found?["result"]?["value"]?.stringValue == marker { return (id, context) }
        }
        return nil
    }

    // MARK: - Windows Chromium opens

    /// Extensions' `tabs.create` becomes a Skylight tab. Other windows extensions open (wallet
    /// approvals, sign-in popups) stay as Chromium's own small windows.
    private func adopt(_ browser: SKForeignBrowser, url: String) {
        guard let target = Self.adoptedURL(url) else { return }
        browser.close()
        openTab?(target)
    }

    static let openPrefix = "about:blank#skylight-open="

    static func adoptedURL(_ address: String) -> URL? {
        guard address.hasPrefix(openPrefix) else { return nil }
        let encoded = String(address.dropFirst(openPrefix.count))
        return encoded.removingPercentEncoding.flatMap(URL.init(string:))
    }

    // MARK: - The shim

    static func workerScript(_ tabs: TabsSnapshot) -> String {
        "\(shim);globalThis.__skylightTabs && Object.assign(globalThis.__skylightTabs.state, \(tabs.json.serialized()));"
    }

    /// Fills the gaps Alloy leaves in `chrome.tabs` and `chrome.windows`. Runs in service workers
    /// (where Skylight pushes the tab list in) and in extension pages (which ask for it).
    static let shim = #"""
    (() => {
      const c = globalThis.chrome;
      if (globalThis.__skylightTabs || !c || !c.tabs) return;
      const WINDOW = 1;
      const state = { active: null, all: [] };
      const page = typeof window !== 'undefined' && window.__skylight;
      Object.defineProperty(globalThis, '__skylightTabs', { value: { state }, enumerable: false });
      const tabs = c.tabs, windows = c.windows;
      const native = { get: tabs.get.bind(tabs), update: tabs.update.bind(tabs), create: windows && windows.create.bind(windows) };
      const fresh = async () => {
        if (page) { try { Object.assign(state, await page.post({ type: 'extensions.tabs' })); } catch (_) {} }
        return state;
      };
      const promised = (fn) => function (...args) {
        const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        const result = fn(...args);
        if (!callback) return result;
        result.then((value) => callback(value), () => callback());
      };
      const dress = (tab, index, active) => Object.assign({}, tab, {
        windowId: WINDOW, index, active: tab.id === active, highlighted: tab.id === active, selected: tab.id === active,
      });
      const pattern = (p) => {
        if (p === '<all_urls>') return /^(https?|file|ftp):/;
        const m = /^(\*|https?|file|ftp|wss?):\/\/(\*|\*\.[^/*]+|[^/*]*)(\/.*)$/.exec(p);
        if (!m) return /$^/;
        const esc = (s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
        const scheme = m[1] === '*' ? 'https?' : esc(m[1]);
        const host = m[2] === '*' ? '[^/]*' : m[2].startsWith('*.') ? '([^/]*\\.)?' + esc(m[2].slice(2)) : esc(m[2]);
        return new RegExp('^' + scheme + '://' + host + '(:\\d+)?' + esc(m[3]).replace(/\\\*/g, '.*').replace(/\*/g, '.*') + '$');
      };
      const glob = (g) => new RegExp('^' + g.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
      const all = async () => {
        const { active, all: ids } = await fresh();
        const found = await Promise.all(ids.map((id) => native.get(id).catch(() => null)));
        return found.filter(Boolean).map((tab, i) => dress(tab, i, active));
      };
      tabs.query = promised(async (info = {}) => {
        if (info.windowId != null && info.windowId !== WINDOW && info.windowId !== -2) return [];
        let list = await all();
        if (info.active != null) list = list.filter((t) => t.active === info.active);
        if (info.highlighted != null) list = list.filter((t) => t.highlighted === info.highlighted);
        if (info.index != null) list = list.filter((t) => t.index === info.index);
        if (info.status) list = list.filter((t) => t.status === info.status);
        if (info.title) list = list.filter((t) => glob(info.title).test(t.title || ''));
        if (info.url) {
          const patterns = [].concat(info.url).map(pattern);
          list = list.filter((t) => t.url && patterns.some((p) => p.test(t.url)));
        }
        return list;
      });
      const current = async () => (await fresh()).active;
      tabs.update = promised(async (a, b) => {
        const [id, props] = typeof a === 'number' ? [a, b] : [await current(), a];
        return native.update(id, props || {});
      });
      tabs.create = promised(async (props = {}) => {
        const url = new URL(props.url || 'about:blank', c.runtime.getURL('')).href;
        if (page) await page.post({ type: 'extensions.openTab', url }).catch(() => {});
        else if (native.create) {
          await native.create({ url: 'about:blank#skylight-open=' + encodeURIComponent(url), focused: false, type: 'popup', width: 1, height: 1 }).catch(() => {});
        }
        return { id: -1, index: 0, windowId: WINDOW, url, pendingUrl: url, active: props.active !== false, highlighted: false,
                 pinned: false, incognito: false, selected: false, discarded: false, autoDiscardable: true, groupId: -1 };
      });
      if (windows) {
        const own = async (q = {}) => ({ id: WINDOW, focused: true, top: 0, left: 0, width: 1280, height: 800, incognito: false,
                                          type: 'normal', state: 'normal', alwaysOnTop: false, tabs: q.populate ? await all() : undefined });
        const getAll = windows.getAll.bind(windows), get = windows.get.bind(windows);
        windows.getCurrent = promised(own);
        windows.getLastFocused = promised(own);
        windows.get = promised(async (id, q) => (id === WINDOW || id === -2 ? own(q) : get(id, q || {})));
        windows.getAll = promised(async (q = {}) => [await own(q), ...(await getAll(q).catch(() => []))]);
      }
    })();
    """#
}
