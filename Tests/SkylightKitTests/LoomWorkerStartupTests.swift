import AppKit
import Foundation
import Testing
import WebKit
@testable import SkylightKit

@Suite @MainActor
struct LoomWorkerStartupTests {
    @Test func recorderCommandReachesAColdWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: "html"), withIntermediateDirectories: true)
        let manifest = #"""
        {"manifest_version":3,"name":"Synthetic worker","description":"Test fixture","version":"1.0",
         "action":{"default_popup":"html/popup.html"},"background":{"service_worker":"worker.js"}}
        """#
        try Data(manifest.utf8).write(to: source.appending(path: "manifest.json"))
        let worker = """
        let commands = 0;
        chrome.runtime.onMessage.addListener((message, sender, respond) => {
          if (message.type === 'extensionIconClicked') respond(String(++commands));
          return false;
        });
        """
        try Data(worker.utf8).write(to: source.appending(path: "worker.js"))
        let popup = #"<html><head><script src="/popup.js"></script></head><body>waiting</body></html>"#
        try Data(popup.utf8).write(to: source.appending(path: "html/popup.html"))
        let page = """
        window.addEventListener('load', () => {
          chrome.runtime.sendMessage({ type: 'bulkStartTaskMetrics' });
          chrome.runtime.sendMessage({ type: 'extensionIconClicked' })
            .then((answer) => { document.body.textContent = String(answer); });
        });
        """
        try Data(page.utf8).write(to: source.appending(path: "popup.js"))

        // Only the ID selects the compatibility behavior. All files and storage are synthetic.
        let prepared = try ExtensionRuntime.prepare(source, id: ExtensionRuntime.loomID, in: root.appending(path: "runtime"))
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
        context.hasAccessToPrivateData = true // Synthetic, nonpersistent store only.
        try controller.load(context)
        let webConfiguration = try #require(context.webViewConfiguration)
        try #require(!webConfiguration.websiteDataStore.isPersistent)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 120), configuration: webConfiguration)
        view.load(URLRequest(url: context.baseURL.appendingPathComponent("html/popup.html")))
        var result: String?
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            result = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                view.evaluateJavaScript("document.body?.textContent") { value, _ in
                    done.resume(returning: value as? String)
                }
            }
            if result == "1" { break }
        }
        #expect(result == "1")
        try controller.unload(context)
    }
}
