import AppKit
import Testing
import WebKit
@testable import SkylightBrowser

@Suite @MainActor
struct PasswordPageScriptTests {
    private func evaluate(_ script: String, in view: WKWebView) async -> String? {
        await withCheckedContinuation { done in
            view.evaluateJavaScript(script) { value, _ in done.resume(returning: value as? String) }
        }
    }

    private func page(_ html: String = "<html><body></body></html>") async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let stub = "window.__reports = []; window.__skylight = { post: m => { __reports.push(m.type); return Promise.resolve(); } };"
        config.userContentController.addUserScript(WKUserScript(source: stub + PasswordService.pageScript,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        view.loadHTMLString(html, baseURL: nil)
        for _ in 0..<100 {
            if await evaluate("document.readyState === 'complete' && window.__skylightPasswords ? 'ready' : 'waiting'", in: view) == "ready" { return view }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func reports(_ view: WKWebView) async -> String? {
        await evaluate("JSON.stringify(window.__reports)", in: view)
    }

    @Test func detectsInitialPasswordOnce() async throws {
        let view = try await page("<html><body><input type='password'><input type='password'></body></html>")
        #expect(await reports(view) == #"["passwords.form"]"#)
        _ = await evaluate("document.body.appendChild(document.createElement('div')); 'ok'", in: view)
        #expect(await reports(view) == #"["passwords.form"]"#)
    }

    @Test func detectsInsertedAndChangedPasswordFields() async throws {
        let inserted = try await page()
        _ = await evaluate("let wrap=document.createElement('div'); wrap.innerHTML='<input type=password>'; document.body.appendChild(wrap); 'ok'", in: inserted)
        #expect(await reports(inserted) == #"["passwords.form"]"#)

        let changed = try await page("<html><body><input id='login' type='text'></body></html>")
        #expect(await reports(changed) == "[]")
        _ = await evaluate("document.getElementById('login').type='password'; 'ok'", in: changed)
        #expect(await reports(changed) == #"["passwords.form"]"#)
    }

    @Test func ignoresRemovedNodesAndAvoidsFullDocumentRescans() async throws {
        let view = try await page()
        _ = await evaluate("""
          window.documentScans = 0;
          const original = Document.prototype.querySelector;
          Document.prototype.querySelector = function(s) { window.documentScans++; return original.call(this, s); };
          for (let i=0; i<10; i++) document.body.appendChild(document.createElement('div'));
          let removed = document.createElement('input'); removed.type='password';
          document.body.appendChild(removed); removed.remove();
          'ok'
          """, in: view)
        #expect(await reports(view) == "[]")
        #expect(await evaluate("String(window.documentScans)", in: view) == "0")
        _ = await evaluate("let input=document.createElement('input'); input.type='password'; document.body.appendChild(input); 'ok'", in: view)
        #expect(await reports(view) == #"["passwords.form"]"#)
    }

    @Test func largeBatchesScanChangedBranchesAndFindNestedPasswords() async throws {
        let view = try await page()
        _ = await evaluate("""
          window.documentScans = 0;
          const original = Document.prototype.querySelector;
          Document.prototype.querySelector = function(s) { window.documentScans++; return original.call(this, s); };
          for (let i=0; i<40; i++) document.body.appendChild(document.createElement('div'));
          'ok'
          """, in: view)
        #expect(await reports(view) == "[]")
        #expect(await evaluate("String(window.documentScans)", in: view) == "0")
        _ = await evaluate("""
          const outer = document.createElement('section');
          document.body.appendChild(outer);
          for (let i=0; i<40; i++) outer.appendChild(document.createElement('div'));
          const field = document.createElement('input'); field.type = 'password';
          outer.lastChild.appendChild(field);
          'ok'
          """, in: view)
        #expect(await reports(view) == #"["passwords.form"]"#)
        #expect(await evaluate("String(window.documentScans)", in: view) == "0")
    }
}
