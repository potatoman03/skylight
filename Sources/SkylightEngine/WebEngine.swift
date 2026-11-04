import AppKit
import SkylightCore

/// The browser engine, as the rest of Skylight sees it. Implemented by SkylightCEF today;
/// a self-built Chromium or WebKit could conform without the app changing.
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

    /// Closes every page, then calls `completion` once the engine can shut down.
    func closeAll(completion: @escaping @MainActor () -> Void)
}

@MainActor
public protocol WebProfile: AnyObject {
    var directory: URL { get }
}

@MainActor
public protocol WebPage: AnyObject {
    /// The view that displays the page. Owned by the page; the UI only hosts it.
    var view: NSView { get }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()

    /// Tells the engine the page is (not) on screen, so it can throttle work.
    func setVisible(_ visible: Bool)

    /// Runs `expression` (may be a Promise) in the main frame and returns its JSON result.
    func evaluate(_ expression: String) async throws -> JSONValue

    func showDeveloperTools()
    func close()
}

/// A permission a site asks for, answered by the UI.
public struct PermissionRequest: Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case camera, microphone, screen, geolocation, notifications, clipboard, midi
        case fileSystem, storageAccess, windowManagement, localFonts, idleDetection
        case keyboardLock, pointerLock, protocolHandler, multipleDownloads, other
    }

    public let id: UInt64
    public let origin: String
    public let kinds: [Kind]
    public let respond: @MainActor @Sendable (Bool) -> Void

    public init(id: UInt64, origin: String, kinds: [Kind], respond: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.id = id
        self.origin = origin
        self.kinds = kinds
        self.respond = respond
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
