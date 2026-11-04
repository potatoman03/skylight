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

        public init(cacheRoot: URL, logFile: URL? = nil, useMockKeychain: Bool = false, remoteDebuggingPort: Int = 0) {
            self.cacheRoot = cacheRoot
            self.logFile = logFile
            self.useMockKeychain = useMockKeychain
            self.remoteDebuggingPort = remoteDebuggingPort
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
    public init() {
        SKEngine.setPageScripts([Self.bootstrapScript])
    }

    public func makeProfile(directory: URL) -> WebProfile {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CEFProfile(directory: directory)
    }

    public func makePage(url: URL, profile: WebProfile, delegate: WebPageDelegate) -> WebPage {
        guard let profile = profile as? CEFProfile else { preconditionFailure("CEFEngine pages need a CEFProfile") }
        return CEFPage(url: url, profile: profile, delegate: delegate)
    }

    public func setPageScripts(_ scripts: [String]) {
        SKEngine.setPageScripts([Self.bootstrapScript] + scripts)
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

@MainActor
final class CEFProfile: WebProfile {
    let directory: URL
    let native: SKProfile

    init(directory: URL) {
        self.directory = directory
        self.native = SKProfile(cachePath: directory.path)
    }
}

/// Lets main-thread-only Objective-C objects ride along in `@Sendable` closures.
struct MainThreadBox<T>: @unchecked Sendable {
    let value: T
}
