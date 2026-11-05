import AppKit
import CEFBridge
import SkylightCore
import SkylightEngine

/// Process-level CEF lifecycle: load, initialize, run, shut down.
public enum CEFRuntime {
    public struct Configuration: Sendable {
        public var cacheRoot: URL
        public var logFile: URL?
        /// Avoids the login-keychain prompt for unsigned development builds.
        public var useMockKeychain: Bool
        public var remoteDebuggingPort: Int
        /// The profile Chromium starts in.
        public var defaultProfile: URL?
        public var extensions: Bool
        /// Unpacked extensions every profile loads. Chromium reads the list once, at launch.
        public var extensionFolders: [URL]
        /// Where to keep the extension that tells Skylight each page's tab id.
        public var extensionHelper: URL?

        public init(cacheRoot: URL, logFile: URL? = nil, useMockKeychain: Bool = false, remoteDebuggingPort: Int = 0,
                    defaultProfile: URL? = nil, extensions: Bool = true, extensionFolders: [URL] = [], extensionHelper: URL? = nil) {
            self.cacheRoot = cacheRoot
            self.logFile = logFile
            self.useMockKeychain = useMockKeychain
            self.remoteDebuggingPort = remoteDebuggingPort
            self.defaultProfile = defaultProfile
            self.extensions = extensions
            self.extensionFolders = extensionFolders
            self.extensionHelper = extensionHelper
        }
    }

    public enum Failure: Error { case frameworkMissing, initializationFailed }

    /// Creates the CEF-aware NSApplication. Must run before anything touches `NSApp`.
    @MainActor public static func makeApplication() -> NSApplication { SKApplication.shared }

    /// Loads and initializes Chromium. `ready` runs once pages can be created.
    @MainActor
    public static func start(_ config: Configuration, ready: @escaping @MainActor () -> Void) throws {
        guard SKEngine.loadFramework() else { throw Failure.frameworkMissing }
        try? FileManager.default.createDirectory(at: config.cacheRoot, withIntermediateDirectories: true)
        let settings = SKEngineSettings()
        settings.rootCachePath = config.cacheRoot.path
        settings.logFilePath = config.logFile?.path
        settings.useMockKeychain = config.useMockKeychain
        settings.remoteDebuggingPort = config.remoteDebuggingPort
        if let profile = config.defaultProfile {
            try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            settings.defaultProfilePath = profile.path
        }
        settings.enableDevToolsPipe = config.extensions
        var folders = config.extensionFolders
        if let helper = config.extensionHelper {
            CEFExtensionHost.writeHelper(to: helper)
            folders.insert(helper, at: 0)
        }
        settings.extensionPaths = folders.map(\.path)
        // CEF calls back on the main thread.
        guard SKEngine.initialize(with: settings, ready: { MainActor.assumeIsolated { ready() } }) else {
            throw Failure.initializationFailed
        }
    }

    /// Blocks until `quit()`.
    public static func runMessageLoop() { SKEngine.runMessageLoop() }
    public static func quit() { SKEngine.quitMessageLoop() }
    public static func shutdown() { SKEngine.shutdown() }

    /// Route Quit through `handler`, so pages close before the process exits.
    @MainActor public static func onTerminate(_ handler: @escaping @MainActor () -> Void) {
        (NSApp as? SKApplication)?.terminationHandler = { MainActor.assumeIsolated { handler() } }
    }
}

/// `WebEngine` backed by the Chromium Embedded Framework.
@MainActor
public final class CEFEngine: WebEngine {
    public let extensions: ExtensionHost?

    public init() {
        extensions = SKEngine.hasDevToolsPipe() ? CEFExtensionHost() : nil
        SKEngine.setPageScripts(Self.engineScripts)
        PictureInPictureWindows.roundCorners()
    }

    private static var engineScripts: [String] { [bootstrapScript, tabIDScript, extensionPageScript] }

    public func makeProfile(directory: URL) -> WebProfile {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CEFProfile(directory: directory)
    }

    public func copyExtensionData(_ ids: [String], from profile: WebProfile, to directory: URL) async throws {
        let source = profile.directory
        try await Task.detached {
            for id in ids {
                for folder in ["Local Extension Settings/\(id)", "Sync Extension Settings/\(id)",
                               "IndexedDB/chrome-extension_\(id)_0.indexeddb.leveldb",
                               "IndexedDB/chrome-extension_\(id)_0.indexeddb.blob"] {
                    try Self.copyDatabase(from: source.appending(path: folder), to: directory.appending(path: folder))
                }
            }
        }.value
    }

    /// Copies a folder the source profile may be using. Its LOCK stays behind, and a file the
    /// database compacted away while we copied is no loss.
    private nonisolated static func copyDatabase(from source: URL, to target: URL) throws {
        let files = FileManager.default
        guard let paths = try? files.subpathsOfDirectory(atPath: source.path) else { return }
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        for path in paths where (path as NSString).lastPathComponent != "LOCK" {
            let file = source.appending(path: path)
            let copy = target.appending(path: path)
            var isFolder: ObjCBool = false
            guard files.fileExists(atPath: file.path, isDirectory: &isFolder) else { continue }
            do {
                if isFolder.boolValue {
                    try files.createDirectory(at: copy, withIntermediateDirectories: true)
                } else {
                    try files.copyItem(at: file, to: copy)
                }
            } catch where !files.fileExists(atPath: file.path) {}
        }
    }

    public func makePage(url: URL, profile: WebProfile, delegate: WebPageDelegate) -> WebPage {
        guard let profile = profile as? CEFProfile else { preconditionFailure("CEFEngine pages need a CEFProfile") }
        return CEFPage(url: url, profile: profile, delegate: delegate)
    }

    public func setPageScripts(_ scripts: [String]) {
        SKEngine.setPageScripts(Self.engineScripts + scripts)
    }

    public func closeAll(completion: @escaping @MainActor () -> Void) {
        SKEngine.closeAllBrowsers { MainActor.assumeIsolated { completion() } }
    }

    /// Implements `window.__skylight.post` on top of CEF's message router, then hides the raw router
    /// function from the page.
    static let bootstrapScript = """
    (() => {
      if (window.__skylight) return;
      const query = window.cefQuery;
      if (typeof query !== 'function') return;
      try { delete window.cefQuery; delete window.cefQueryCancel; } catch (_) {}
      const post = (message) => new Promise((resolve, reject) => {
        query({
          request: JSON.stringify(message),
          persistent: false,
          onSuccess: (response) => { try { resolve(JSON.parse(response)); } catch (_) { resolve(response); } },
          onFailure: (_code, error) => reject(new Error(error)),
        });
      });
      Object.defineProperty(window, '__skylight', {
        value: Object.freeze({ post }), configurable: false, enumerable: false, writable: false,
      });
    })();
    """
}

extension CEFEngine {
    /// Passes on the tab id the helper extension writes into the page (see `CEFExtensionHost`).
    static let tabIDScript = """
    (() => {
      if (!window.__skylight || !/^(https?|file):$/.test(location.protocol)) return;
      let sent = false;
      const report = () => {
        const root = document.documentElement;
        const id = root && Number(root.getAttribute('data-skylight-tab'));
        if (sent || !id) return;
        sent = true;
        window.__skylight.post({ type: '__skylight.tabID', id }).catch(() => {});
      };
      const watch = () => {
        report();
        if (!sent) new MutationObserver((_, observer) => { report(); if (sent) observer.disconnect(); })
          .observe(document.documentElement, { attributes: true, attributeFilter: ['data-skylight-tab'] });
      };
      if (document.documentElement) watch(); else document.addEventListener('readystatechange', watch, { once: true });
    })();
    """

    /// In extension pages (popups, options): the tabs shim, and the page's preferred size so a
    /// popup can fit its content the way Chrome's do.
    static let extensionPageScript = """
    (() => {
      if (location.protocol !== 'chrome-extension:' || !window.__skylight) return;
      const install = () => { \(CEFExtensionHost.shim) };
      install();
      // Chromium adds the extension APIs just after this runs. Mutation callbacks run before
      // the parser executes the page's first script, so the shim is in place by then.
      if (!globalThis.__skylightTabs) {
        queueMicrotask(install);
        const early = new MutationObserver(() => { install(); if (globalThis.__skylightTabs) early.disconnect(); });
        early.observe(document, { childList: true, subtree: true });
      }
      let last = '';
      const measure = () => {
        const root = document.documentElement;
        if (!root || !document.body) return;
        const width = root.style.width;
        root.style.width = 'max-content';
        const w = Math.ceil(root.getBoundingClientRect().width);
        root.style.width = width;
        const h = Math.ceil(Math.max(root.scrollHeight, document.body.scrollHeight));
        const key = w + 'x' + h;
        if (key === last) return;
        last = key;
        window.__skylight.post({ type: 'extensions.size', width: w, height: h }).catch(() => {});
      };
      const watch = () => {
        new ResizeObserver(measure).observe(document.body);
        new MutationObserver(() => requestAnimationFrame(measure)).observe(document.body, { childList: true, subtree: true, attributes: true });
        measure();
      };
      if (document.body) watch(); else document.addEventListener('DOMContentLoaded', watch, { once: true });
    })();
    """
}

@MainActor
final class CEFProfile: WebProfile {
    let directory: URL
    let native: SKProfile

    init(directory: URL) {
        self.directory = directory
        self.native = SKProfile(cachePath: directory.path)
    }

    func cookieNames(domains: [String]) async -> Set<String> {
        await withCheckedContinuation { done in
            native.cookieNames(forDomains: domains) { done.resume(returning: $0) }
        }
    }

    func copyCookies(domains: [String], to profile: WebProfile) async -> Int {
        guard let target = (profile as? CEFProfile)?.native else { return 0 }
        return await withCheckedContinuation { done in
            native.copyCookies(forDomains: domains, to: target) { done.resume(returning: $0) }
        }
    }

    func addCookies(_ cookies: [WebCookie]) async -> Int {
        let native = cookies.map {
            SKCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure,
                     httpOnly: $0.isHTTPOnly, expires: $0.expires, sameSite: $0.sameSite.rawValue)
        }
        return await withCheckedContinuation { done in
            self.native.add(native) { done.resume(returning: $0) }
        }
    }
}

/// Lets main-thread-only Objective-C objects ride along in `@Sendable` closures.
struct MainThreadBox<T>: @unchecked Sendable {
    let value: T
}

/// Chromium's Picture in Picture window comes square, with a hairline border. Rounded like other
/// floating windows, it sits better over the desktop.
@MainActor
enum PictureInPictureWindows {
    static let radius: CGFloat = 12
    private static var observer: NSObjectProtocol?

    static func roundCorners() {
        guard observer == nil else { return }
        // Posted when any window comes on screen, Chromium's own included.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: nil, queue: .main) { note in
            let window = MainThreadBox(value: note.object as? NSWindow)
            MainActor.assumeIsolated {
                guard let window = window.value, isPictureInPicture(window) else { return }
                round(window)
            }
        }
    }

    /// Chromium names the window for what it is, and floats it.
    private static func isPictureInPicture(_ window: NSWindow) -> Bool {
        window.level == .floating && window.title == "Picture in Picture"
    }

    private static func round(_ window: NSWindow) {
        // The window's frame view, so the clip takes in everything Chromium draws in the window.
        guard let view = window.contentView?.superview ?? window.contentView, view.layer?.cornerRadius != radius else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        window.invalidateShadow()
    }
}
