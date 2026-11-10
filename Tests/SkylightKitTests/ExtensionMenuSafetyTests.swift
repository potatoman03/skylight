import AppKit
import Foundation
import Testing
import WebKit
@testable import SkylightKit

@Suite @MainActor
struct ExtensionMenuSafetyTests {
    /// A popup creates the menu, then a cold worker removes it. Older system WebKit versions
    /// terminate the content process when the worker's menu API has not been used before.
    @Test(arguments: ["callback", "promise", "missingCallback", "missingPromise"])
    func removingMenuFromWorkerPreservesOtherMenus(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: "html"), withIntermediateDirectories: true)
        let manifest = #"""
        {"manifest_version":3,"name":"Synthetic menu","description":"Isolated fixture","version":"1.0",
         "permissions":["contextMenus"],"action":{"default_popup":"html/popup.html"},
         "background":{"service_worker":"worker.js"}}
        """#
        let worker = #"""
        let phase = 'idle';
        const checkOther = (outcome) => {
          chrome.contextMenus.update('other', { title: 'still present' }, () => {
            const error = chrome.runtime.lastError;
            phase = error ? 'other-error:' + error.message : outcome;
          });
        };
        chrome.runtime.onMessage.addListener((message, sender, reply) => {
          if (message.type === 'status') reply(phase);
          if (message.type === 'remove') {
            phase = 'pending';
            const mode = message.mode;
            const missing = mode.startsWith('missing');
            const id = missing ? 'missing' : 'fixture';
            if (mode === 'callback' || mode === 'missingCallback') {
              chrome.contextMenus.remove(id, () => {
                const error = chrome.runtime.lastError;
                if (missing) checkOther(error ? 'missing-error' : 'unexpected-success');
                else if (error) phase = 'remove-error:' + error.message;
                else checkOther('removed');
              });
            } else {
              chrome.contextMenus.remove(id).then(
                () => missing ? checkOther('unexpected-success') : checkOther('removed'),
                error => missing ? checkOther('missing-error') : phase = 'remove-error:' + error.message
              );
            }
            reply('started');
          }
          return false;
        });
        """#
        let page = #"""
        window.addEventListener('load', () => {
          const mode = new URL(location.href).searchParams.get('mode');
          const poll = () => chrome.runtime.sendMessage({type:'status'}).then((value) => {
            if (value !== 'idle') { setTimeout(poll, 100); return; }
            chrome.contextMenus.create({id:'fixture', title:'fixture'}, () => {
              let error = chrome.runtime.lastError;
              if (error) { document.body.textContent = 'create-error:' + error.message; return; }
              chrome.contextMenus.create({id:'other', title:'other'}, () => {
                error = chrome.runtime.lastError;
                if (error) { document.body.textContent = 'create-error:' + error.message; return; }
                chrome.runtime.sendMessage({type:'remove', mode}).then(() => {
                  setInterval(() => chrome.runtime.sendMessage({type:'status'}).then((v) => {
                    document.body.textContent = String(v);
                  }), 100);
                });
              });
            });
          });
          poll();
        });
        """#
        let files = ["manifest.json": manifest, "worker.js": worker,
                     "html/popup.html": "<html><head><script src='/page.js'></script></head><body>waiting</body></html>",
                     "page.js": page]
        for (name, contents) in files { try Data(contents.utf8).write(to: source.appending(path: name)) }
        let runtime = root.appending(path: "runtime")
        _ = try ExtensionRuntime.prepare(source, id: "syntheticmenu", in: runtime)
        let prepared = try ExtensionRuntime.prepare(source, id: "syntheticmenu", in: runtime)
        let ext = try await WKWebExtension(resourceBaseURL: prepared.folder)
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.defaultWebsiteDataStore = store
        let base = WKWebViewConfiguration()
        base.websiteDataStore = store
        configuration.webViewConfiguration = base
        let controller = WKWebExtensionController(configuration: configuration)
        let context = WKWebExtensionContext(for: ext)
        let id = "fixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        context.uniqueIdentifier = id
        context.baseURL = try #require(URL(string: "webkit-extension://\(id)/"))
        context.hasAccessToPrivateData = true
        try controller.load(context)
        for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        let webConfig = try #require(context.webViewConfiguration)
        #expect(!webConfig.websiteDataStore.isPersistent)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 120), configuration: webConfig)
        var url = URLComponents(url: context.baseURL.appendingPathComponent("html/popup.html"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "mode", value: mode)]
        view.load(URLRequest(url: try #require(url.url)))
        var result = ""
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            result = await withCheckedContinuation { done in
                view.evaluateJavaScript("document.body?.textContent") { value, _ in
                    done.resume(returning: value as? String ?? "")
                }
            }
            if result == "removed" || result == "missing-error" || result.contains("error") || result == "unexpected-success" { break }
        }
        #expect(result == (mode.hasPrefix("missing") ? "missing-error" : "removed"))
        try controller.unload(context)
    }
}
