import AppKit
import CEFBridge
import SkylightCore
import SkylightEngine

/// One tab's Chromium browser.
@MainActor
final class CEFPage: NSObject, WebPage {
    private var browser: SKBrowser!
    private weak var delegate: WebPageDelegate?
    private var pendingEvaluations: [String: CheckedContinuation<JSONValue, Error>] = [:]

    static let evaluationTimeout: Duration = .seconds(15)

    init(url: URL, profile: CEFProfile, delegate: WebPageDelegate) {
        self.delegate = delegate
        super.init()
        browser = SKBrowser(url: url.absoluteString, profile: profile.native, delegate: self)
    }

    var view: NSView { browser.view }

    func load(_ url: URL) { browser.loadURL(url.absoluteString) }
    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }
    func reload() { browser.reload() }
    func stop() { browser.stopLoad() }
    func setVisible(_ visible: Bool) { browser.setHidden(!visible) }
    func showDeveloperTools() { browser.showDevTools() }
    func close() { browser.close() }

    func evaluate(_ expression: String) async throws -> JSONValue {
        guard !browser.isClosed else { throw WebEngineError.pageClosed }
        let id = UUID().uuidString
        let script = """
        (async () => {
          let result = null, error = null;
          try { result = await (\(expression)); } catch (e) { error = String((e && e.message) || e); }
          if (result === undefined) result = null;
          window.__skylight && window.__skylight.post({ type: '__skylight.eval', id: '\(id)', result, error });
        })();
        """
        return try await withCheckedThrowingContinuation { continuation in
            pendingEvaluations[id] = continuation
            browser.executeJavaScript(script)
            Task { [weak self] in
                try? await Task.sleep(for: Self.evaluationTimeout)
                self?.finishEvaluation(id, .failure(WebEngineError.script("Timed out waiting for the page.")))
            }
        }
    }

    private func finishEvaluation(_ id: String, _ result: Result<JSONValue, Error>) {
        pendingEvaluations.removeValue(forKey: id)?.resume(with: result)
    }

    private func emit(_ build: (inout PageEvent) -> Void) {
        var event = PageEvent()
        build(&event)
        delegate?.page(self, didChange: event)
    }
}

extension CEFPage: @preconcurrency SKBrowserDelegate {
    func browser(_ browser: SKBrowser, didChangeAddress url: String) {
        emit { $0.url = URL(string: url) }
    }

    func browser(_ browser: SKBrowser, didChangeTitle title: String) {
        emit { $0.title = title }
    }

    func browser(_ browser: SKBrowser, didChangeFaviconURL url: String) {
        emit { $0.faviconURL = URL(string: url) }
    }

    func browser(_ browser: SKBrowser, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        emit {
            $0.isLoading = loading
            $0.canGoBack = canGoBack
            $0.canGoForward = canGoForward
        }
    }

    func browser(_ browser: SKBrowser, didChangeProgress progress: Double) {
        emit { $0.progress = progress }
    }

    func browser(_ browser: SKBrowser, wantsNewTabWithURL url: String, background: Bool) {
        guard let url = URL(string: url) else { return }
        delegate?.page(self, wantsNewTab: url, inBackground: background)
    }

    func browser(_ browser: SKBrowser, receivedQuery request: String, reply: @escaping (String?, String?) -> Void) {
        let reply = MainThreadBox(value: reply)
        guard let message = try? JSONValue.parse(request) else {
            reply.value(nil, "Malformed message")
            return
        }
        if message["type"]?.stringValue == "__skylight.eval", let id = message["id"]?.stringValue {
            if let error = message["error"]?.stringValue {
                finishEvaluation(id, .failure(WebEngineError.script(error)))
            } else {
                finishEvaluation(id, .success(message["result"] ?? .null))
            }
            reply.value("null", nil)
            return
        }
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { reply.value(nil, "No handler"); return }
            do {
                let result = try await delegate.page(self, didReceive: message)
                reply.value(result.serialized(), nil)
            } catch {
                reply.value(nil, error.localizedDescription)
            }
        }
    }

    func browser(_ browser: SKBrowser, requestsPermission request: SKPermissionRequest) {
        let box = MainThreadBox(value: request)
        let kinds = request.kinds.map { PermissionRequest.Kind(rawValue: $0) ?? .other }
        delegate?.page(self, requestsPermission: PermissionRequest(
            id: request.requestID, origin: request.origin, kinds: kinds,
            respond: { allow in box.value.respond(allow) }
        ))
    }

    func browser(_ browser: SKBrowser, requestsDialog request: SKDialogRequest) {
        let box = MainThreadBox(value: request)
        let kind: DialogRequest.Kind = switch request.kind {
        case .alert: .alert
        case .confirm: .confirm
        default: .prompt
        }
        delegate?.page(self, requestsDialog: DialogRequest(
            kind: kind, origin: request.origin, message: request.message, defaultText: request.defaultText,
            respond: { ok, text in box.value.respond(ok, text: text) }
        ))
    }

    func browser(_ browser: SKBrowser, didFinishDownloadAtPath path: String) {
        delegate?.page(self, didFinishDownload: URL(fileURLWithPath: path))
    }

    func browserDidClose(_ browser: SKBrowser) {
        for id in pendingEvaluations.keys { finishEvaluation(id, .failure(WebEngineError.pageClosed)) }
        delegate?.pageDidClose(self)
    }
}
