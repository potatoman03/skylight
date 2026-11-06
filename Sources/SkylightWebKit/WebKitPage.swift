import AppKit
import SkylightCore
import SkylightEngine
import WebKit

/// One tab's web view.
@MainActor
final class WebKitPage: NSObject, SkylightEngine.WebPage {
    let webView: WKWebView
    private weak var delegate: WebPageDelegate?
    private let didClose: (WebKitPage) -> Void
    private var observations: [NSKeyValueObservation] = []
    private var pendingEvaluations: [UUID: CheckedContinuation<JSONValue, Error>] = [:]
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var isClosed = false
    weak var extensionWindow: ExtensionWindow?
    weak var extensionController: WKWebExtensionController?
    private static var nextPermission: UInt64 = 1

    static let evaluationTimeout: Duration = .seconds(15)

    init(configuration: WKWebViewConfiguration, delegate: WebPageDelegate, didClose: @escaping (WebKitPage) -> Void) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.delegate = delegate
        self.didClose = didClose
        super.init()
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
    }

    var view: NSView { webView }

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func hardReload() { webView.reloadFromOrigin() }
    func stop() { webView.stopLoading() }
    func setVisible(_ visible: Bool) { webView.isHidden = !visible }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        observations.removeAll()
        for id in Array(pendingEvaluations.keys) { finishEvaluation(id, .failure(WebEngineError.pageClosed)) }
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        didClose(self)
        delegate?.pageDidClose(self)
    }

    /// WebKit runs scripts from the app as if the user had asked.
    func runWithUserGesture(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// WebKit gives a fullscreen element a window of its own, so Skylight's stays as it is.
    func exitFullscreen() {
        webView.closeAllMediaPresentations(completionHandler: nil)
    }

    /// The public API can only offer a page to Safari's Develop menu, so this asks for the
    /// inspector the way Safari does, and does nothing if WebKit stops offering it.
    func showDeveloperTools() {
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter), let inspector = webView.perform(getter)?.takeUnretainedValue() as? NSObject
        else { return }
        let isOpen = inspector.responds(to: NSSelectorFromString("isVisible")) && inspector.value(forKey: "visible") as? Bool == true
        let action = NSSelectorFromString(isOpen ? "close" : "show")
        if inspector.responds(to: action) { inspector.perform(action) }
    }

    func evaluate(_ expression: String) async throws -> JSONValue {
        guard !isClosed else { throw WebEngineError.pageClosed }
        let id = UUID()
        let body = "return JSON.stringify((await (\(expression))) ?? null);"
        return try await withCheckedThrowingContinuation { continuation in
            pendingEvaluations[id] = continuation
            webView.callAsyncJavaScript(body, in: nil, in: .page) { [weak self] result in
                switch result {
                case let .success(value):
                    let parsed = (value as? String).flatMap { try? JSONValue.parse($0) } ?? .null
                    self?.finishEvaluation(id, .success(parsed))
                case let .failure(error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    self?.finishEvaluation(id, .failure(WebEngineError.script(message ?? error.localizedDescription)))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.evaluationTimeout)
                self?.finishEvaluation(id, .failure(WebEngineError.script("Timed out waiting for the page.")))
            }
        }
    }

    func receive(_ message: JSONValue, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return reply(nil, "No handler") }
            do {
                let result = try await delegate.page(self, didReceive: message)
                reply(result.serialized(), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    private func finishEvaluation(_ id: UUID, _ result: Result<JSONValue, Error>) {
        pendingEvaluations.removeValue(forKey: id)?.resume(with: result)
    }

    private func emit(_ build: (inout PageEvent) -> Void) {
        var event = PageEvent()
        build(&event)
        delegate?.page(self, didChange: event)
    }

    private func watch<Value>(_ path: KeyPath<WKWebView, Value>, _ changed: @escaping @MainActor (WebKitPage) -> Void) {
        observations.append(webView.observe(path, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                if let self { changed(self) }
            }
        })
    }

    private func observe() {
        watch(\.url) { page in
            page.emit { $0.url = page.webView.url }
            page.extensionController?.didChangeTabProperties(.URL, for: page)
        }
        watch(\.title) { page in
            page.emit { $0.title = page.webView.title }
            page.extensionController?.didChangeTabProperties(.title, for: page)
        }
        watch(\.estimatedProgress) { page in page.emit { $0.progress = page.webView.estimatedProgress } }
        watch(\.isLoading) { page in
            page.emitNavigationState()
            page.extensionController?.didChangeTabProperties(.loading, for: page)
        }
        watch(\.canGoBack) { $0.emitNavigationState() }
        watch(\.canGoForward) { $0.emitNavigationState() }
    }

    private func emitNavigationState() {
        emit {
            $0.isLoading = webView.isLoading
            $0.canGoBack = webView.canGoBack
            $0.canGoForward = webView.canGoForward
        }
    }

    /// WebKit doesn't report favicons, so ask the page, in a world its own scripts can't reach.
    private func reportFavicon() {
        let script = """
        (() => {
          if (!/^https?:$/.test(location.protocol)) return null;
          const icon = document.querySelector('link[rel~="icon"][href]');
          return icon ? icon.href : new URL('/favicon.ico', location.href).href;
        })();
        """
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard case let .success(value) = result, let text = value as? String, let url = URL(string: text) else { return }
            self?.emit { $0.faviconURL = url }
        }
    }

    private func showFailure(_ error: Error, for url: URL?) {
        let error = error as NSError
        // A cancelled load, or one that turned into a download, isn't a failure.
        guard error.code != NSURLErrorCancelled, error.domain != WKErrorDomain || error.code != 102 else { return }
        let message = error.localizedDescription.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Can't open page</title>
        <body style="font: 15px -apple-system; display: grid; place-items: center; height: 90vh; color: GrayText">
        <p>\(message)</p></body>
        """
        webView.loadHTMLString(html, baseURL: url)
    }

    /// Where a download goes: Downloads, with a number added if the name is taken.
    private nonisolated static func destination(for name: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = name.isEmpty ? "download" : (name as NSString).lastPathComponent
        var path = folder.appending(path: name)
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: path.path) {
            path = folder.appending(path: suffix.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(suffix)")
            number += 1
        }
        return path
    }

    /// Links for other apps open only from a click, and only the kinds people expect to.
    private static let externalSchemes: Set<String> = ["mailto", "tel", "facetime", "sms"]
    private static let webSchemes: Set<String> = ["http", "https", "about", "file", "blob", "data", "webkit-extension"]
}

extension WebKitPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if !Self.webSchemes.contains(scheme) {
            if action.navigationType == .linkActivated, Self.externalSchemes.contains(scheme), let url = action.request.url {
                NSWorkspace.shared.open(url)
            }
            return decisionHandler(.cancel, preferences)
        }
        // A ⌘-click or middle click opens a tab. WebKit reports buttons as a mask, so middle is 4.
        let opensTab = action.modifierFlags.contains(.command) || action.buttonNumber == 4
        if action.navigationType == .linkActivated, opensTab, let url = action.request.url {
            delegate?.page(self, wantsNewTab: url, inBackground: !action.modifierFlags.contains(.shift))
            return decisionHandler(.cancel, preferences)
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = disposition?.lowercased().hasPrefix("attachment") == true
        decisionHandler(response.canShowMIMEType && !isAttachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        reportFavicon()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error, for: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension WebKitPage: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let destination = Self.destination(for: suggestedFilename)
        downloads[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        delegate?.page(self, didFinishDownload: file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads[ObjectIdentifier(download)] = nil
    }
}

extension WebKitPage: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Real popups keep their opener, because sign-in flows depend on it. Anything else is a tab.
        if windowFeatures.isPopup { return WebKitPopup.open(configuration, features: windowFeatures, over: webView.window) }
        if let url = action.request.url {
            let inBackground = action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift)
            delegate?.page(self, wantsNewTab: url, inBackground: inBackground)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        requestDialog(.alert, frame, message, "") { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        requestDialog(.confirm, frame, message, "") { ok, _ in completionHandler(ok) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        requestDialog(.prompt, frame, prompt, defaultText ?? "") { ok, text in completionHandler(ok ? text : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let kinds: [PermissionRequest.Kind] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        let id = Self.nextPermission
        Self.nextPermission += 1
        let answer = MainThreadBox(value: decisionHandler)
        delegate?.page(self, requestsPermission: PermissionRequest(
            id: id, origin: origin.text, topOrigin: webView.url.map { PermissionRequest.origin(of: $0.absoluteString) }, kinds: kinds,
            respond: { allow in answer.value(allow ? .grant : .deny) }
        ))
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    private func requestDialog(_ kind: DialogRequest.Kind, _ frame: WKFrameInfo, _ message: String, _ defaultText: String,
                               _ finish: @escaping @MainActor (Bool, String) -> Void) {
        let finish = MainThreadBox(value: finish)
        guard let delegate else { return finish.value(false, "") }
        delegate.page(self, requestsDialog: DialogRequest(
            kind: kind, origin: frame.securityOrigin.text, message: message, defaultText: defaultText,
            respond: { ok, text in finish.value(ok, text) }
        ))
    }
}

extension WKSecurityOrigin {
    /// As a browser writes it: scheme, host, and a port if there is one.
    var text: String {
        "\(`protocol`)://\(host)" + (port == 0 ? "" : ":\(port)")
    }
}

extension WKWindowFeatures {
    /// `window.open` with a size, a position or no toolbar. Chromium draws the same line.
    var isPopup: Bool {
        width != nil || height != nil || x != nil || y != nil || toolbarsVisibility?.boolValue == false
    }
}

/// Lets main-actor closures ride along in `@Sendable` ones.
struct MainThreadBox<T>: @unchecked Sendable {
    let value: T
}

/// A sign-in popup, in a small window of its own.
@MainActor
final class WebKitPopup: NSObject, WKUIDelegate, NSWindowDelegate {
    private static var open: [ObjectIdentifier: WebKitPopup] = [:]
    private let webView: WKWebView
    private let window: NSWindow
    private var title: NSKeyValueObservation?

    static func open(_ configuration: WKWebViewConfiguration, features: WKWindowFeatures, over parent: NSWindow?) -> WKWebView {
        let popup = WebKitPopup(configuration, features: features, over: parent)
        open[ObjectIdentifier(popup)] = popup
        return popup.webView
    }

    private init(_ configuration: WKWebViewConfiguration, features: WKWindowFeatures, over parent: NSWindow?) {
        let size = NSSize(width: features.width.map { CGFloat($0.doubleValue) } ?? 500,
                          height: features.height.map { CGFloat($0.doubleValue) } ?? 640)
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        webView.uiDelegate = self
        title = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.window.title = webView.title ?? "" }
        }
        if let parent {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if windowFeatures.isPopup { return Self.open(configuration, features: windowFeatures, over: window) }
        webView.load(action.request)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[ObjectIdentifier(self)] = nil
    }
}
