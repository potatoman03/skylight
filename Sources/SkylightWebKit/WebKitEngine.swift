import AppKit
import SkylightCore
import SkylightEngine
import WebKit

/// `WebEngine` backed by the system's WebKit. There's nothing to start or shut down, and codecs and
/// DRM come from macOS.
@MainActor
public final class WebKitEngine: NSObject, WebEngine {
    /// Every page shares these, so a new set of scripts reaches each one at its next load.
    private let contentController = WKUserContentController()
    private var pages: [ObjectIdentifier: WebKitPage] = [:]

    private let extensionHost = WebKitExtensionHost()
    public var extensions: ExtensionHost? { extensionHost }

    public override init() {
        super.init()
        contentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageHandler)
        setPageScripts([])
    }

    public func makeProfile(directory: URL) -> WebProfile {
        WebKitProfile(directory: directory)
    }

    public func makePage(url: URL, profile: WebProfile, delegate: WebPageDelegate) -> SkylightEngine.WebPage {
        guard let profile = profile as? WebKitProfile else { preconditionFailure("WebKitEngine pages need a WebKitProfile") }
        let page = WebKitPage(configuration: configuration(for: profile, url: url), delegate: delegate) { [weak self] page in
            self?.pages[ObjectIdentifier(page.webView)] = nil
        }
        pages[ObjectIdentifier(page.webView)] = page
        extensionHost.open(page, in: profile)
        page.load(url)
        return page
    }

    public func setPageScripts(_ scripts: [String]) {
        contentController.removeAllUserScripts()
        for source in [Self.bootstrapScript] + scripts {
            contentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: true, in: .page))
        }
    }

    public func closeAll() {
        for page in Array(pages.values) { page.close() }
    }

    /// WebKit keeps extension storage to itself, so a new Space's extensions start fresh.
    public func copyExtensionData(_ ids: [String], from profile: WebProfile, to directory: URL) async throws {}

    public func deleteProfile(_ profile: WebProfile) async {
        guard let profile = profile as? WebKitProfile else { return }
        for page in pages.values where page.webView.configuration.websiteDataStore === profile.store { page.close() }
        extensionHost.forget(profile)
        try? await WKWebsiteDataStore.remove(forIdentifier: profile.identifier)
    }

    private func configuration(for profile: WebKitProfile, url: URL) -> WKWebViewConfiguration {
        let controller = extensionHost.controller(for: profile)
        let configuration: WKWebViewConfiguration
        if let extensionPage = extensionHost.configuration(for: url, in: controller) {
            // An extension's own pages run in its context, with no page scripts of ours. They're
            // related to its background page, and WKWebView throws unless they share its data store.
            configuration = extensionPage
        } else {
            configuration = WKWebViewConfiguration()
            configuration.webExtensionController = controller
            configuration.userContentController = contentController
            configuration.websiteDataStore = profile.store
        }
        // Sound waits for a click, as in Chrome. Muted video plays by itself.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.preferences.isElementFullscreenEnabled = true
        // Inspect Element in a page's context menu.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Without this, sites see an unknown browser and some refuse to serve video.
        let system = ProcessInfo.processInfo.operatingSystemVersion
        configuration.applicationNameForUserAgent = "Version/\(system.majorVersion).\(system.minorVersion) Safari/605.1.15"
        return configuration
    }

    private static let messageHandler = "skylight"

    /// Implements `window.__skylight.post` on top of a WebKit message handler.
    static let bootstrapScript = """
    (() => {
      if (window.__skylight) return;
      const handlers = window.webkit && window.webkit.messageHandlers;
      const bridge = handlers && handlers.\(messageHandler);
      if (!bridge) return;
      const send = bridge.postMessage.bind(bridge);
      const post = async (message) => {
        const reply = await send(JSON.stringify(message));
        try { return JSON.parse(reply); } catch (_) { return reply; }
      };
      Object.defineProperty(window, '__skylight', {
        value: Object.freeze({ post }), configurable: false, enumerable: false, writable: false,
      });
    })();
    """
}

extension WebKitEngine: WKScriptMessageHandlerWithReply {
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        // The handler reaches every frame, but only the main frame's page scripts speak for the page.
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let page = pages[ObjectIdentifier(webView)], let body = message.body as? String,
              let parsed = try? JSONValue.parse(body)
        else { return replyHandler(nil, "Malformed message") }
        page.receive(parsed, reply: replyHandler)
    }
}

/// One Space's cookies and storage, in a WebKit data store. WebKit decides where a store lives on
/// disk, so `directory` only keeps the store's identifier.
@MainActor
final class WebKitProfile: WebProfile {
    let directory: URL
    let identifier: UUID
    let store: WKWebsiteDataStore

    init(directory: URL) {
        self.directory = directory
        identifier = Self.storeIdentifier(in: directory)
        store = WKWebsiteDataStore(forIdentifier: identifier)
    }

    /// Kept beside the profile rather than worked out from its path, so two data folders never
    /// share a store, and a moved folder keeps its own.
    static func storeIdentifier(in directory: URL) -> UUID {
        let file = directory.appending(path: "webkit-store")
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let identifier = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return identifier
        }
        let identifier = UUID()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? identifier.uuidString.write(to: file, atomically: true, encoding: .utf8)
        return identifier
    }

    func cookieNames(domains: [String]) async -> Set<String> {
        Set(await cookies(within: domains).map(\.name))
    }

    func copyCookies(domains: [String], to profile: WebProfile) async -> Int {
        guard let target = profile as? WebKitProfile else { return 0 }
        let cookies = await cookies(within: domains)
        for cookie in cookies { await target.set(cookie) }
        return cookies.count
    }

    func addCookies(_ cookies: [WebCookie]) async -> Int {
        // The same value set twice isn't an import: a second run should say nothing's new.
        var have = Set(await allCookies().map(Self.identity(of:)))
        var added = 0
        for cookie in cookies {
            guard let native = Self.native(cookie), have.insert(Self.identity(of: native)).inserted else { continue }
            await set(native)
            added += 1
        }
        return added
    }

    private static func identity(of cookie: HTTPCookie) -> String {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return [domain, cookie.path, cookie.name, cookie.value].joined(separator: "\n")
    }

    /// A domain matches itself and its subdomains, whichever way the cookie spells it.
    static func isWithin(_ cookieDomain: String, _ domains: [String]) -> Bool {
        let host = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func native(_ cookie: WebCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path,
        ]
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = cookie.expires { properties[.expires] = expires }
        switch cookie.sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .none, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }

    private func cookies(within domains: [String]) async -> [HTTPCookie] {
        await allCookies().filter { Self.isWithin($0.domain, domains) }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { done in
            store.httpCookieStore.getAllCookies { done.resume(returning: $0) }
        }
    }

    private func set(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) { done.resume() }
        }
    }
}
