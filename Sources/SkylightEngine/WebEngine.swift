import AppKit
import SkylightCore

/// The browser engine, as the rest of Skylight sees it. Implemented by SkylightWebKit.
///
/// ## Page script contract
/// Every engine must give page scripts, before any page script runs:
/// - `window.__skylight.post(message) -> Promise<any>`: sends a JSON-serializable message to
///   `WebPageDelegate.page(_:didReceive:)` and resolves with its reply.
/// - The scripts passed to `setPageScripts(_:)`, run in order at document start in the main frame.
@MainActor
public protocol WebEngine: AnyObject {
    /// One cookie jar and cache, rooted at `directory`. Spaces each get their own.
    func makeProfile(directory: URL) -> WebProfile

    func makePage(url: URL, profile: WebProfile, delegate: WebPageDelegate) -> WebPage

    /// Scripts injected into every page from now on (packages, agent helpers, WebMCP).
    func setPageScripts(_ scripts: [String])

    /// Closes every page.
    func closeAll()

    /// Chrome extensions, when the engine can run them.
    var extensions: ExtensionHost? { get }
    /// Copies what these extensions keep in `profile` into the profile folder `directory`. Do this
    /// before that folder's profile is made, while nothing has it open.
    func copyExtensionData(_ ids: [String], from profile: WebProfile, to directory: URL) async throws
    /// Closes the profile's pages and deletes its cookies and storage.
    func deleteProfile(_ profile: WebProfile) async
}

/// One profile's pages, as its extensions see them.
public struct ExtensionTabs {
    public let profile: WebProfile
    public let pages: [WebPage]
    /// The tab extensions treat as current. Nil unless the profile's Space is on screen.
    public let active: WebPage?

    public init(profile: WebProfile, pages: [WebPage], active: WebPage?) {
        self.profile = profile
        self.pages = pages
        self.active = active
    }
}

/// An extension's popup, for Skylight to show under its button.
public struct ExtensionPopup {
    public let id: String
    public let view: NSView
    public let close: @MainActor () -> Void

    public init(id: String, view: NSView, close: @escaping @MainActor () -> Void) {
        self.id = id
        self.view = view
        self.close = close
    }
}

/// Runs Chrome extensions. Every profile runs them all, each with its own storage.
///
/// The engine has no tab strip of its own, so extensions get a current tab and a window from
/// Skylight: `setTabs` says which pages exist and which one is in front, and `openTab` receives
/// the tabs extensions ask for.
@MainActor
public protocol ExtensionHost: AnyObject {
    /// Loads an unpacked extension folder as `id`.
    func load(_ directory: URL, id: String) async throws
    func unload(_ id: String) async throws
    /// Drops every extension's stored service worker, so the next run loads each one from disk.
    func forgetWorkers() async
    /// The pages each profile's extensions can see.
    func setTabs(_ groups: [ExtensionTabs])
    /// Clicks the extension's toolbar button: its popup opens, or `action.onClicked` fires.
    func triggerAction(_ id: String, page: WebPage?) async throws
    /// The address of one of the extension's own pages.
    func pageURL(_ id: String, path: String) -> URL?
    /// An extension asked to open a tab.
    var openTab: (@MainActor (URL) -> Void)? { get set }
    /// A popup is ready to show.
    var showPopup: (@MainActor (ExtensionPopup) -> Void)? { get set }
    /// The open popup's content wants this size.
    var resizePopup: (@MainActor (CGSize) -> Void)? { get set }
}

@MainActor
public protocol WebProfile: AnyObject {
    var directory: URL { get }
    /// The names of the cookies set for these domains and their subdomains. Never their values.
    func cookieNames(domains: [String]) async -> Set<String>
    /// Copies the cookies for these domains and their subdomains. Returns how many were copied.
    func copyCookies(domains: [String], to profile: WebProfile) async -> Int
    /// Adds cookies from elsewhere, keeping any this profile already has. Returns how many were added.
    func addCookies(_ cookies: [WebCookie]) async -> Int
}

@MainActor
public protocol WebPage: AnyObject {
    /// The view that displays the page. Owned by the page; the UI only hosts it.
    var view: NSView { get }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    /// Reloads without using anything cached.
    func hardReload()
    func stop()

    /// Tells the engine the page is (not) on screen, so it can throttle work.
    func setVisible(_ visible: Bool)

    /// Runs `expression` (may be a Promise) in the main frame and returns its JSON result.
    func evaluate(_ expression: String) async throws -> JSONValue

    func showDeveloperTools()
    func close()

    /// Runs `script` as if the user had just clicked, for APIs that need a gesture
    /// (picture in picture, fullscreen). Fire and forget.
    func runWithUserGesture(_ script: String)

    /// Brings the page out of fullscreen, if it's in it.
    func exitFullscreen()
}

/// A permission a site asks for, answered by the UI.
public struct PermissionRequest: Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case camera, microphone, screen, geolocation, notifications, clipboard, midi
        case fileSystem, storageAccess, windowManagement, localFonts, idleDetection
        case keyboardLock, pointerLock, protocolHandler, multipleDownloads, other
    }

    public let id: UInt64
    /// The site asking, which may be a frame inside the page.
    public let origin: String
    /// The site of the page it's asking in. An answer for a site holds only within the same
    /// page's site, so allowing maps.example its camera doesn't let any page that embeds it use it.
    public let topOrigin: String
    public let kinds: [Kind]
    public let respond: @MainActor @Sendable (Bool) -> Void

    public init(id: UInt64, origin: String, topOrigin: String? = nil, kinds: [Kind], respond: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.id = id
        self.origin = origin
        self.topOrigin = topOrigin.flatMap { $0.isEmpty ? nil : $0 } ?? origin
        self.kinds = kinds
        self.respond = respond
    }

    /// Asked from a frame of another site than the page's.
    public var isEmbedded: Bool { Self.origin(of: origin) != Self.origin(of: topOrigin) }

    /// scheme://host[:port] of an address, the way origins compare.
    public static func origin(of address: String) -> String {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased()
        else { return address }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

/// `alert`, `confirm` and `prompt` from a page.
public struct DialogRequest: Identifiable, Sendable {
    public enum Kind: Sendable { case alert, confirm, prompt }

    public let id = UUID()
    public let kind: Kind
    public let origin: String
    public let message: String
    public let defaultText: String
    /// `ok` false means cancel. `text` is used for prompts.
    public let respond: @MainActor @Sendable (_ ok: Bool, _ text: String) -> Void

    public init(kind: Kind, origin: String, message: String, defaultText: String,
                respond: @escaping @MainActor @Sendable (Bool, String) -> Void) {
        self.kind = kind
        self.origin = origin
        self.message = message
        self.defaultText = defaultText
        self.respond = respond
    }
}

public struct PageEvent: Sendable, Equatable {
    public var url: URL?
    public var title: String?
    public var faviconURL: URL?
    public var isLoading: Bool?
    public var canGoBack: Bool?
    public var canGoForward: Bool?
    public var progress: Double?
    /// The page went into fullscreen (a video's fullscreen button) or came out of it.
    public var isFullscreen: Bool?

    public init() {}
}

@MainActor
public protocol WebPageDelegate: AnyObject {
    func page(_ page: WebPage, didChange event: PageEvent)
    func page(_ page: WebPage, wantsNewTab url: URL, inBackground: Bool)
    /// A message from `window.__skylight.post`. The reply resolves the page's promise.
    func page(_ page: WebPage, didReceive message: JSONValue) async throws -> JSONValue
    func page(_ page: WebPage, requestsPermission request: PermissionRequest)
    func page(_ page: WebPage, requestsDialog request: DialogRequest)
    func page(_ page: WebPage, didFinishDownload fileURL: URL)
    func pageDidClose(_ page: WebPage)
}

public enum WebEngineError: Error, LocalizedError {
    case pageClosed
    case script(String)

    public var errorDescription: String? {
        switch self {
        case .pageClosed: "The page was closed."
        case let .script(message): message
        }
    }
}
