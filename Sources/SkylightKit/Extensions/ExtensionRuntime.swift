import CryptoKit
import Foundation

/// Gets a Chrome extension ready to run on WebKit. WebKit leaves out a few Chrome APIs, and an
/// extension's service worker dies if it touches one while it starts, which takes the whole
/// extension down. Nothing can be injected ahead of an extension's scripts, so an extension with a
/// worker runs from a copy that loads `compatibility` first: in its worker, its pages and its
/// content scripts. The folder it was installed in stays as it was.
public enum ExtensionRuntime {
    static let compatibilityFile = "skylight-compatibility.js"
    static let pageCompatibilityFile = "skylight-page-compatibility.js"
    static let workerFile = "skylight-worker.js"
    static let loomID = "liecbddmkiiihnedobmlmillhodjkdmb"
    static let loomReadyWorkerFile = "skylight-loom-ready-worker.js"
    static let loomReadyPageFile = "skylight-loom-ready-page.js"

    /// Loom's popup sends its recorder command immediately, while WebKit may still be starting the
    /// worker. A command sent during that interval can resolve without reaching any listener.
    static let loomReadyWorker = """
    chrome.runtime.onMessage.addListener((message, sender, respond) => {
      if (sender.id === chrome.runtime.id && message?.type === '__skylight_loom_worker_ready__') {
        respond('__skylight_loom_ready__');
      }
      return false;
    });
    """

    /// Wait only for Loom's recorder command. Its other messages and all other extensions keep
    /// their normal semantics; if the worker never starts, send the command after a bounded wait.
    static let loomReadyPage = """
    (() => {
      const runtime = globalThis.chrome?.runtime;
      if (!runtime?.sendMessage) return;
      const send = runtime.sendMessage.bind(runtime);
      const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
      let pending;
      const ready = () => pending ??= (async () => {
        for (let attempt = 0; attempt < 30; attempt++) {
          const answer = await Promise.race([
            send({ type: '__skylight_loom_worker_ready__' }).catch(() => undefined),
            delay(100),
          ]);
          if (answer === '__skylight_loom_ready__') return;
          await delay(50);
        }
      })();
      runtime.sendMessage = (...args) => {
        if (args.length !== 1 || args[0]?.type !== 'extensionIconClicked') return send(...args);
        return ready().then(() => send(...args));
      };
    })();
    """

    /// Safari's engine keeps `requestIdleCallback` behind a flag, and scripts written for Chrome
    /// assume it. Without it Proton Pass never finds a page's login forms, and nothing says why.
    static let idleCallback = """
    if (typeof document !== 'undefined' && !globalThis.requestIdleCallback) {
      globalThis.requestIdleCallback = (callback) => setTimeout(() => {
        const start = performance.now();
        callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (performance.now() - start)) });
      }, 1);
      globalThis.cancelIdleCallback = (handle) => clearTimeout(handle);
    }
    """

    /// Stands in for what's missing: events that never fire, and answers saying there's nothing
    /// there. Offscreen documents can't be made, so asking for one fails as it would for any other
    /// reason. Extensions already have to handle that. The same goes for the rest of Chrome's APIs
    /// that WebKit leaves out: extensions rely on them whether or not they matter here, and a worker
    /// that reads `chrome.notifications.onClicked` when there's no such thing never runs. Something
    /// an extension can only want done, like a download, fails instead of pretending it worked.
    static let compatibility = """
    (() => {
      const api = globalThis.chrome;
      if (!api || !api.runtime) return;
      // WebKit holds its API objects' script wrappers weakly, so a wrapper nothing refers to is
      // collected and the next read gets a new one, without what was added to it here.
      Object.defineProperty(api, Symbol('skylight.runtime'), { value: api.runtime });
      // WebKit delivers events through these globals, in workers, pages and content scripts alike.
      // Proton Pass replaces them with a guard once it's running, and a script that does that
      // never hears anything again.
      if (Object.getOwnPropertyDescriptor(globalThis, 'chrome')?.configurable === false) return;
      for (const name of ['chrome', 'browser']) {
        Object.defineProperty(globalThis, name, { get: () => api, set: () => {}, configurable: false });
      }
      const add = (object, name, value) => { if (!(name in object)) object[name] = value; };
      const event = () => {
        const listeners = new Set();
        return {
          addListener: (listener) => { listeners.add(listener); },
          removeListener: (listener) => { listeners.delete(listener); },
          hasListener: (listener) => listeners.has(listener),
        };
      };
      for (const name of ['onUpdateAvailable', 'onRestartRequired', 'onSuspend', 'onSuspendCanceled']) {
        add(api.runtime, name, event());
      }
      add(api.runtime, 'requestUpdateCheck', async (callback) => {
        const result = { status: 'no_update' };
        if (callback) callback(result.status, {});
        return result;
      });
      add(api.runtime, 'getContexts', async () => []);
      add(api, 'offscreen', {
        hasDocument: async () => false,
        createDocument: async () => { throw new Error('Offscreen documents are not available.'); },
        closeDocument: async () => {},
      });
      \(idleCallback)
      // Content scripts never had the rest.
      if (!api.tabs) return;
      for (const name of ['action', 'cookies', 'extension', 'i18n', 'permissions', 'scripting', 'storage', 'tabs', 'webNavigation', 'webRequest', 'windows']) {
        if (api[name]) Object.defineProperty(api, Symbol(`skylight.${name}`), { value: api[name] });
      }
      const answer = (value) => (...args) => {
        const last = args[args.length - 1];
        if (typeof last === 'function') last(value);
        return Promise.resolve(value);
      };
      const refuse = (what) => async () => { throw new Error(`${what} isn't available in Skylight.`); };
      const stub = (events, methods = {}) => {
        const object = {};
        for (const name of events) object[name] = event();
        for (const [name, value] of Object.entries(methods)) object[name] = typeof value === 'function' ? value : answer(value);
        return object;
      };
      const setting = (value) => stub(['onChange'], {
        get: { value, levelOfControl: 'not_controllable' }, set: undefined, clear: undefined,
      });
      const settings = (value, names) => Object.fromEntries(names.map((name) => [name, setting(value)]));
      const manifest = api.runtime.getManifest?.() ?? {};
      for (const name of ['move', 'discard', 'highlight', 'ungroup']) add(api.tabs, name, answer());
      add(api.tabs, 'group', answer(-1));
      if (api.action) {
        add(api.action, 'setBadgeTextColor', answer());
        add(api.action, 'getBadgeTextColor', answer([0, 0, 0, 0]));
        add(api.action, 'getUserSettings', answer({ isOnToolbar: true }));
      }
      if (api.storage) add(api.storage, 'managed', stub(['onChanged'], { get: {}, getBytesInUse: 0 }));
      if (api.webNavigation) {
        for (const name of ['onCreatedNavigationTarget', 'onHistoryStateUpdated', 'onReferenceFragmentUpdated', 'onTabReplaced']) {
          add(api.webNavigation, name, event());
        }
      }
      if (api.webRequest) add(api.webRequest, 'handlerBehaviorChanged', answer());
      // WebKit rejects Chrome's file wildcard and rejects the entire registration with it. Keep
      // the supported patterns so an extension can still register on the web. Do not claim that
      // a file-only registration succeeded: let WebKit reject that request as before.
      if (api.scripting?.registerContentScripts) {
        const register = api.scripting.registerContentScripts.bind(api.scripting);
        api.scripting.registerContentScripts = (scripts, ...args) => register(scripts.map((script) => {
          const matches = script.matches?.filter((match) => match !== 'file://*/*');
          return matches?.length ? { ...script, matches } : script;
        }), ...args);
      }
      if (api.windows) add(api.windows, 'onBoundsChanged', event());
      if (api.i18n) add(api.i18n, 'detectLanguage', answer({ isReliable: false, languages: [] }));
      if (api.permissions) {
        add(api.permissions, 'addHostAccessRequest', answer());
        add(api.permissions, 'removeHostAccessRequest', answer());
      }
      if (api.cookies) add(api.cookies, 'getPartitionKey', answer({ partitionKey: {} }));
      if (api.extension) add(api.extension, 'getURL', (path) => api.runtime.getURL(path));
      const missing = {
        bookmarks: stub(['onCreated', 'onRemoved', 'onChanged', 'onMoved', 'onChildrenReordered', 'onImportBegan', 'onImportEnded'], {
          get: [], getTree: [], getChildren: [], getRecent: [], getSubTree: [], search: [],
          create: refuse('Bookmarks'), move: refuse('Bookmarks'), remove: refuse('Bookmarks'), removeTree: refuse('Bookmarks'), update: refuse('Bookmarks'),
        }),
        browsingData: stub([], { remove: refuse('Clearing browsing data'), settings: { options: {}, dataToRemove: {}, dataRemovalPermitted: {} } }),
        commands: stub(['onCommand', 'onChanged'], { getAll: [] }),
        contentSettings: Object.fromEntries(['automaticDownloads', 'camera', 'cookies', 'fullscreen', 'images', 'javascript', 'location', 'microphone', 'mouselock', 'notifications', 'plugins', 'popups'].map((name) => [name, stub([], {
          get: { setting: 'ask' }, set: undefined, clear: undefined, getResourceIdentifiers: [],
        })])),
        debugger: stub(['onEvent', 'onDetach'], { attach: refuse('Debugging'), detach: undefined, sendCommand: refuse('Debugging'), getTargets: [] }),
        declarativeContent: {
          onPageChanged: { ...event(), addRules: answer(), removeRules: answer(), getRules: answer([]) },
          PageStateMatcher: class {}, ShowAction: class {}, ShowPageAction: class {}, SetIcon: class {}, RequestContentScript: class {},
        },
        downloads: stub(['onCreated', 'onChanged', 'onErased', 'onDeterminingFilename'], {
          download: refuse('Downloading'), search: [], pause: undefined, resume: undefined, cancel: undefined, erase: [], open: undefined, show: undefined,
          showDefaultFolder: undefined, getFileIcon: undefined, removeFile: undefined, acceptDanger: undefined, setUiOptions: undefined,
        }),
        fontSettings: stub(['onFontChanged', 'onDefaultFontSizeChanged'], { getFontList: [], getFont: { fontId: '', levelOfControl: 'not_controllable' } }),
        gcm: stub(['onMessage', 'onMessagesDeleted', 'onSendError'], { register: refuse('Push messaging'), send: refuse('Push messaging'), unregister: undefined }),
        history: stub(['onVisited', 'onVisitRemoved'], { search: [], getVisits: [], addUrl: undefined, deleteUrl: undefined, deleteRange: undefined, deleteAll: undefined }),
        identity: stub(['onSignInChanged'], {
          getAuthToken: refuse('Google sign-in'), launchWebAuthFlow: refuse('Web sign-in'), getAccounts: [], removeCachedAuthToken: undefined, clearAllCachedAuthTokens: undefined,
          getProfileUserInfo: { email: '', id: '' }, getRedirectURL: (path = '') => `https://${api.runtime.id}.chromiumapp.org/${path}`,
        }),
        idle: stub(['onStateChanged'], { queryState: 'active', setDetectionInterval: undefined, getAutoLockDelay: 0 }),
        instanceID: stub(['onTokenRefresh'], { getID: refuse('Push messaging'), getToken: refuse('Push messaging'), getCreationTime: 0, deleteID: undefined, deleteToken: undefined }),
        management: stub(['onInstalled', 'onUninstalled', 'onEnabled', 'onDisabled'], {
          getSelf: { id: api.runtime.id, name: manifest.name, version: manifest.version, enabled: true, installType: 'normal', type: 'extension', mayDisable: true },
          getAll: [], get: refuse('Other extensions'), getPermissionWarningsById: [], getPermissionWarningsByManifest: [], setEnabled: refuse('Other extensions'),
          uninstall: refuse('Other extensions'), uninstallSelf: refuse('Removing an extension from itself'), launchApp: undefined,
        }),
        notifications: stub(['onClicked', 'onButtonClicked', 'onClosed', 'onPermissionLevelChanged', 'onShowSettings'], {
          create: (...args) => answer(typeof args[0] === 'string' ? args[0] : crypto.randomUUID())(...args),
          update: false, clear: false, getAll: {}, getPermissionLevel: 'denied',
        }),
        pageCapture: stub([], { saveAsMHTML: refuse('Saving a page') }),
        power: stub([], { requestKeepAwake: undefined, releaseKeepAwake: undefined }),
        printing: stub(['onJobStatusChanged'], { submitJob: refuse('Printing'), cancelJob: undefined, getPrinters: [] }),
        privacy: {
          network: { ...settings(true, ['networkPredictionEnabled']), ...settings('default', ['webRTCIPHandlingPolicy']) },
          services: settings(false, ['alternateErrorPagesEnabled', 'autofillAddressEnabled', 'autofillCreditCardEnabled', 'autofillEnabled', 'passwordSavingEnabled',
            'safeBrowsingEnabled', 'safeBrowsingExtendedReportingEnabled', 'searchSuggestEnabled', 'spellingServiceEnabled', 'translationServiceEnabled']),
          websites: settings(false, ['adMeasurementEnabled', 'doNotTrackEnabled', 'fledgeEnabled', 'hyperlinkAuditingEnabled', 'protectedContentEnabled', 'referrersEnabled',
            'relatedWebsiteSetsEnabled', 'thirdPartyCookiesAllowed', 'topicsEnabled']),
        },
        proxy: { settings: setting({ mode: 'system' }), onProxyError: event() },
        search: stub([], { query: refuse('Searching') }),
        sessions: { ...stub(['onChanged'], { getRecentlyClosed: [], getDevices: [], restore: refuse('Restoring a session') }), MAX_SESSION_RESULTS: 25 },
        system: {
          cpu: stub([], { getInfo: { numOfProcessors: 0, archName: '', modelName: '', features: [], processors: [] } }),
          display: stub(['onDisplayChanged'], { getInfo: [] }),
          memory: stub([], { getInfo: { capacity: 0, availableCapacity: 0 } }),
          storage: stub(['onAttached', 'onDetached'], { getInfo: [], ejectDevice: 'failure', getAvailableCapacity: { id: '', availableCapacity: 0 } }),
        },
        tabCapture: stub(['onStatusChanged'], { capture: refuse('Capturing a tab'), getCapturedTabs: [], getMediaStreamId: refuse('Capturing a tab') }),
        tabGroups: { ...stub(['onCreated', 'onMoved', 'onRemoved', 'onUpdated'], { get: refuse('Tab groups'), move: refuse('Tab groups'), query: [], update: refuse('Tab groups') }), TAB_GROUP_ID_NONE: -1 },
        topSites: stub([], { get: [] }),
        tts: stub(['onVoicesChanged'], { speak: refuse('Text to speech'), stop: undefined, pause: undefined, resume: undefined, isSpeaking: false, getVoices: [] }),
        webAuthenticationProxy: stub(['onCreateRequest', 'onGetRequest', 'onIsUvpaaRequest', 'onRemoteSessionStateChange', 'onRequestCanceled'], {
          attach: refuse('The passkey proxy'), detach: undefined,
        }),
      };
      for (const [name, value] of Object.entries(missing)) add(api, name, value);
    })();
    """

    public struct Prepared: Sendable {
        /// Where to run the extension from.
        public let folder: URL
        /// WebKit keeps a worker's scripts and reuses them whatever's on disk, and an update to one
        /// it already has crashes its web process, so a changed worker has to be forgotten first.
        public let workerChanged: Bool
        private let record: URL?
        private let digest: Data?

        fileprivate init(folder: URL, workerChanged: Bool, record: URL? = nil, digest: Data? = nil) {
            self.folder = folder
            self.workerChanged = workerChanged
            self.record = record
            self.digest = digest
        }

        /// Remember a worker only after WebKit has accepted it. Otherwise the next launch must
        /// still discard any older cached worker and try again.
        public func markLoaded() throws {
            if let record, let digest { try digest.write(to: record, options: .atomic) }
        }
    }

    /// `folder` itself if the extension needs nothing, or a fresh copy in `root`.
    public static func prepare(_ folder: URL, id: String, in root: URL) throws -> Prepared {
        let file = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: file),
              var manifest = (try? JSONSerialization.jsonObject(with: ExtensionManifest.withoutComments(data))) as? [String: Any],
              var background = manifest["background"] as? [String: Any],
              let worker = background["service_worker"] as? String
        else { return Prepared(folder: folder, workerChanged: false) }

        let copy = root.appending(path: id, directoryHint: .isDirectory)
        let files = FileManager.default
        try? files.removeItem(at: copy)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try files.copyItem(at: folder, to: copy)

        // Rooted paths, because a relative one would be read against the wrapper's own place.
        let path = "/" + worker.split(separator: "/").joined(separator: "/")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let literal = String(decoding: try encoder.encode(path), as: UTF8.self)
        let wrapper: String
        if background["type"] as? String == "module" {
            wrapper = "import \"/\(compatibilityFile)\";\nimport \(literal);\n"
                + (id == loomID ? "import \"/\(loomReadyWorkerFile)\";\n" : "")
        } else {
            // A classic worker resolves importScripts against the worker's URL, not the imported
            // file. The stable wrapper is at the root, so retain the original worker's base for
            // its relative imports without changing the registered worker URL.
            let base = worker.contains("/") ? """
            (() => {
              const nativeImport = globalThis.importScripts;
              const base = new URL(\(literal), globalThis.location.href);
              globalThis.importScripts = function(...urls) {
                return nativeImport.apply(this, urls.map(url => new URL(url, base).href));
              };
            })();

            """ : ""
            wrapper = base + "importScripts(\"/\(compatibilityFile)\", \(literal));\n"
                + (id == loomID ? "importScripts(\"/\(loomReadyWorkerFile)\");\n" : "")
        }
        try Data(compatibility.utf8).write(to: copy.appending(path: compatibilityFile))
        try Data(idleCallback.utf8).write(to: copy.appending(path: pageCompatibilityFile))
        try Data(wrapper.utf8).write(to: copy.appending(path: workerFile))

        background["service_worker"] = workerFile
        manifest["background"] = background
        if let scripts = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = scripts.map(loadingCompatibility)
        }
        try addCompatibility(toPagesIn: copy)
        if id == loomID {
            try Data(loomReadyWorker.utf8).write(to: copy.appending(path: loomReadyWorkerFile))
            try Data(loomReadyPage.utf8).write(to: copy.appending(path: loomReadyPageFile))
            let popup = copy.appending(path: "html/popup.html")
            if let page = try? String(contentsOf: popup, encoding: .utf8),
               let compatibility = page.range(of: "<script src=\"/\(compatibilityFile)\"></script>") {
                let tag = "<script src=\"/\(loomReadyPageFile)\"></script>"
                try (page[..<compatibility.upperBound] + tag + page[compatibility.upperBound...])
                    .write(to: popup, atomically: true, encoding: .utf8)
            }
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: copy.appending(path: "manifest.json"))

        var hash = SHA256()
        hash.update(data: data)
        hash.update(data: Data(compatibility.utf8))
        hash.update(data: Data(wrapper.utf8))
        if id == loomID { hash.update(data: Data(loomReadyWorker.utf8)) }
        hash.update(data: (try? Data(contentsOf: folder.appending(path: worker))) ?? Data())
        let digest = Data(hash.finalize())
        let record = workerRecord(id: id, in: root)
        let changed = (try? Data(contentsOf: record)) != digest
        return Prepared(folder: copy, workerChanged: changed, record: record, digest: digest)
    }

    /// A page's own world never runs extension APIs, so main world scripts only get what the page lacks.
    private static func loadingCompatibility(_ entry: [String: Any]) -> [String: Any] {
        guard let scripts = entry["js"] as? [String], !scripts.isEmpty else { return entry }
        var entry = entry
        entry["js"] = [entry["world"] as? String == "MAIN" ? pageCompatibilityFile : compatibilityFile] + scripts
        return entry
    }

    private static func addCompatibility(toPagesIn folder: URL) throws {
        let tag = "<script src=\"/\(compatibilityFile)\"></script>"
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where ["html", "htm"].contains(file.pathExtension.lowercased()) {
            guard let page = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard let script = page.range(of: "<script", options: .caseInsensitive) else { continue }
            try (page[..<script.lowerBound] + tag + page[script.lowerBound...]).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func workerRecord(id: String, in root: URL) -> URL {
        root.appending(path: id + ".worker")
    }

    /// Removes a copy made by `prepare`, if there is one.
    public static func discard(id: String, in root: URL) {
        try? FileManager.default.removeItem(at: root.appending(path: id, directoryHint: .isDirectory))
        try? FileManager.default.removeItem(at: workerRecord(id: id, in: root))
    }
}
