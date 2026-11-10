import Foundation
import JavaScriptCore
import Security
import Testing
@testable import SkylightKit

@Suite struct ExtensionManifestTests {
    @Test func readsAnMV3Manifest() throws {
        let json = """
        {
          // Chrome allows comments.
          "manifest_version": 3,
          "name": "__MSG_appName__",
          "version": "1.2.0",
          "icons": { "16": "i16.png", "128": "i128.png" },
          "action": { "default_title": "Do it", "default_popup": "popup.html", "default_icon": { "32": "a32.png" } },
          "options_ui": { "page": "options.html" },
          "permissions": ["tabs", "storage"],
          "host_permissions": ["<all_urls>"]
        }
        """
        let manifest = try ExtensionManifest.parse(Data(json.utf8), messages: ["appname": "Clipper"])
        #expect(manifest.name == "Clipper")
        #expect(manifest.manifestVersion == 3)
        #expect(manifest.action?.popup == "popup.html")
        #expect(manifest.title == "Do it")
        #expect(manifest.optionsPage == "options.html")
        // The action's own icon wins, then the closest size up.
        #expect(manifest.icon(size: 32) == "a32.png")
        #expect(manifest.icon(size: 64) == "i128.png")
        #expect(manifest.warnings == ["Read and change everything on every website", "See your open tabs and their addresses"])
    }

    @Test func readsAnMV2BrowserAction() throws {
        let json = #"{"name":"Old","version":"1","browser_action":{"default_popup":""},"options_page":"o.html"}"#
        let manifest = try ExtensionManifest.parse(Data(json.utf8))
        #expect(manifest.manifestVersion == 2)
        #expect(manifest.action != nil)
        #expect(manifest.action?.popup == nil)
        #expect(manifest.optionsPage == "o.html")
        #expect(manifest.title == "Old")
    }

    @Test func anUpdateCantQuietlyWidenItsAccess() throws {
        func manifest(_ fields: String) throws -> ExtensionManifest {
            try ExtensionManifest.parse(Data(#"{"name":"E","version":"1",\#(fields)}"#.utf8))
        }
        let one = try manifest(#""host_permissions":["https://a.example/*"]"#)
        // Content scripts are access too, and every site is warned about.
        let everywhere = try manifest(#""host_permissions":["https://a.example/*"],"content_scripts":[{"matches":["<all_urls>"]}]"#)
        #expect(everywhere.addedWarnings(since: one) == ["Read and change everything on every website"])
        // The count stays at one site, but the site is a different one.
        let swapped = try manifest(#""host_permissions":["https://bank.example/*"]"#)
        #expect(swapped.warnings == one.warnings)
        #expect(swapped.addedWarnings(since: one) == ["Read and change your data on one more site"])
        // A content script on a site it already had adds nothing.
        let same = try manifest(#""host_permissions":["https://a.example/*"],"content_scripts":[{"matches":["https://a.example/*"]}]"#)
        #expect(same.addedWarnings(since: one).isEmpty)
        // Adding a site says so once, with any new permission after it.
        let two = try manifest(#""host_permissions":["https://a.example/*","https://b.example/*"],"permissions":["history"]"#)
        #expect(two.addedWarnings(since: one) == ["Read and change your data on one more site", "Read your browsing history"])
        // Nothing is left to add once it has every site.
        #expect(try manifest(#""host_permissions":["https://b.example/*"]"#).addedWarnings(since: everywhere).isEmpty)
    }

    @Test func rejectsWhatIsntAManifest() {
        #expect(throws: ExtensionManifest.Failure.self) { try ExtensionManifest.parse(Data("[]".utf8)) }
        #expect(throws: ExtensionManifest.Failure.self) { try ExtensionManifest.parse(Data(#"{"version":"1"}"#.utf8)) }
    }

    @Test func loadsLocalizedNamesFromAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "skylight-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "_locales/en"), withIntermediateDirectories: true)
        try Data(#"{"name":"__MSG_name__","version":"1","default_locale":"en"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
        try Data(#"{"name":{"message":"Localized"}}"#.utf8).write(to: folder.appending(path: "_locales/en/messages.json"))
        #expect(try ExtensionManifest.load(from: folder).name == "Localized")
    }
}

@Suite struct ExtensionIDTests {
    // Expected values computed independently (Python hashlib).
    @Test func idsComeFromTheKeyOrThePath() {
        #expect(ExtensionID.from(path: "/tmp/ext") == "lcfjooiecahccmjaipimfaidcnaihadb")
        #expect(ExtensionID.from(publicKey: Data(0..<40)) == "fpkkeoomdgbbffgibcmcnheledhmimej")
        #expect(ExtensionID.from(manifestKey: "AAECAwQFBgcICQoLDA0ODxAREhMU\nFRYXGBkaGxwdHh8gISIjJCUmJw==") == "fpkkeoomdgbbffgibcmcnheledhmimej")
        #expect(ExtensionID.isValid("fpkkeoomdgbbffgibcmcnheledhmimej"))
        #expect(!ExtensionID.isValid("fpkkeoomdgbbffgibcmcnheledhmimez"))
        #expect(!ExtensionID.isValid("short"))
    }

    @Test(arguments: [
        ("fpkkeoomdgbbffgibcmcnheledhmimej", "fpkkeoomdgbbffgibcmcnheledhmimej"),
        ("https://chromewebstore.google.com/detail/some-name/fpkkeoomdgbbffgibcmcnheledhmimej", "fpkkeoomdgbbffgibcmcnheledhmimej"),
        ("https://chrome.google.com/webstore/detail/x/fpkkeoomdgbbffgibcmcnheledhmimej?hl=en", "fpkkeoomdgbbffgibcmcnheledhmimej"),
        ("https://example.com/detail/fpkkeoomdgbbffgibcmcnheledhmimej", nil),
        ("not an id", nil),
    ] as [(String, String?)])
    func storeLinks(input: String, id: String?) {
        #expect(WebStore.extensionID(from: input) == id)
    }

    @Test func downloadURLAsksForCRX3() throws {
        let url = WebStore.downloadURL(for: "fpkkeoomdgbbffgibcmcnheledhmimej", chromeVersion: "156.0.1.2")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "x" }?.value == "id=fpkkeoomdgbbffgibcmcnheledhmimej&uc")
        #expect(items.first { $0.name == "acceptformat" }?.value == "crx3")
    }
}

@Suite struct CRXTests {
    /// A length-delimited protobuf field.
    func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat {
            out.append(UInt8(v & 0x7F) | (v > 0x7F ? 0x80 : 0))
            v >>= 7
        } while v > 0
        return out
    }

    func crx(header: [UInt8], archive: [UInt8]) -> Data {
        let size = UInt32(header.count)
        let le = [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]
        return Data(Array("Cr24".utf8) + [3, 0, 0, 0] + le + header + archive)
    }

    /// DER length, short or long form.
    func derLength(_ n: Int) -> [UInt8] {
        n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
    }

    /// A fresh RSA key, and its public half as the SubjectPublicKeyInfo Chrome uses.
    func developerKey() throws -> (SecKey, [UInt8]) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pub = try #require(SecKeyCopyPublicKey(key))
        let pkcs1 = [UInt8](try #require(SecKeyCopyExternalRepresentation(pub, nil)) as Data)
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bits = [0x03] + derLength(pkcs1.count + 1) + [0] + pkcs1
        return (key, [0x30] + derLength(algorithm.count + bits.count) + algorithm + bits)
    }

    /// A CRX3 signed the way the store signs one: the developer's proof over the signed data and zip.
    func signedCRX(key: SecKey, publicKey: [UInt8], id: String, archive: [UInt8], extraProof: [UInt8] = []) throws -> Data {
        let alphabet = Array("abcdefghijklmnop")
        let idBytes = stride(from: 0, to: 32, by: 2).map { i -> UInt8 in
            let chars = Array(id)
            return UInt8(alphabet.firstIndex(of: chars[i])! << 4 | alphabet.firstIndex(of: chars[i + 1])!)
        }
        let signedData = field(1, idBytes)
        let n = UInt32(signedData.count)
        let message = Array("CRX3 SignedData\u{0}".utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)] + signedData + archive
        let signature = [UInt8](try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message) as CFData, nil)) as Data)
        let header = extraProof + field(2, field(1, publicKey) + field(2, signature)) + field(10000, signedData)
        return crx(header: header, archive: archive)
    }

    @Test func acceptsAPackageSignedByItsDeveloper() throws {
        let (key, publicKey) = try developerKey()
        let id = ExtensionID.from(publicKey: Data(publicKey))
        let zip = Array("PK\u{3}\u{4}zip".utf8)
        // Another proof (the store's) comes first; the developer's is the one whose key makes the id.
        let store = field(2, field(1, [UInt8](repeating: 7, count: 30)) + field(2, [1, 2]))
        let package = try CRXPackage(signedCRX(key: key, publicKey: publicKey, id: id, archive: zip, extraProof: store), expected: id)
        #expect(package.publicKey == Data(publicKey))
        #expect(package.id == id)
        #expect(package.archive == Data(zip))
    }

    @Test func rejectsATamperedOrMislabelledPackage() throws {
        let (key, publicKey) = try developerKey()
        let id = ExtensionID.from(publicKey: Data(publicKey))
        var tampered = [UInt8](try signedCRX(key: key, publicKey: publicKey, id: id, archive: Array("PK\u{3}\u{4}zip".utf8)))
        tampered[tampered.count - 1] ^= 1
        #expect(throws: CRXPackage.Failure.badSignature) { try CRXPackage(Data(tampered)) }

        // Signed by its developer, but not the extension asked for.
        let good = try signedCRX(key: key, publicKey: publicKey, id: id, archive: [1, 2, 3])
        #expect(throws: CRXPackage.Failure.wrongExtension) { try CRXPackage(good, expected: String(repeating: "a", count: 32)) }

        // Claiming someone else's id: no proof's key makes that id.
        let (_, otherKey) = try developerKey()
        let stolen = try signedCRX(key: key, publicKey: publicKey, id: ExtensionID.from(publicKey: Data(otherKey)), archive: [1, 2, 3])
        #expect(throws: CRXPackage.Failure.badSignature) { try CRXPackage(stolen) }
    }

    @Test func readsStoreUpdateChecks() {
        let reply = """
        <?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
        <app appid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" status="ok"><updatecheck codebase="https://example/x.crx" version="2.1.0" status="ok"/></app>
        <app appid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" status="ok"><updatecheck status="noupdate"/></app>
        </gupdate>
        """
        #expect(WebStore.availableVersions(in: Data(reply.utf8)) == ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": "2.1.0"])
        #expect(WebStore.isVersion("1.10", laterThan: "1.9"))
        #expect(WebStore.isVersion("2.0.1", laterThan: "2.0"))
        #expect(!WebStore.isVersion("2.0", laterThan: "2.0.0"))
        let url = WebStore.updateCheckURL(for: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": "1.0"], chromeVersion: "156")
        #expect(url.absoluteString.contains("x=id%3Daaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa%26v%3D1.0%26uc"))
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: CRXPackage.Failure.notCRX) { try CRXPackage(Data("PK\u{3}\u{4}not a crx".utf8)) }
        var v2 = [UInt8](crx(header: [], archive: [0]))
        v2[4] = 2
        #expect(throws: CRXPackage.Failure.unsupportedVersion(2)) { try CRXPackage(Data(v2)) }
    }
}

@Suite struct ExtensionRuntimeTests {
    private func folder(manifest: String) throws -> (root: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: source.appending(path: "manifest.json"))
        try Data("// the extension's own".utf8).write(to: source.appending(path: "background.js"))
        return (root, source)
    }

    private func text(_ file: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appending(path: file), encoding: .utf8)
    }

    private func worker(in folder: URL) throws -> String {
        let data = try Data(contentsOf: folder.appending(path: "manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require((manifest["background"] as? [String: Any])?["service_worker"] as? String)
    }

    /// What it adds to `chrome.runtime` lives on a wrapper WebKit holds weakly. Losing it only
    /// shows in a worker big enough to trigger a collection while it starts.
    @Test func theCompatibilityScriptKeepsTheRuntimeObjectAlive() {
        let pin = ExtensionRuntime.compatibility.range(of: "value: api.runtime")
        let first = ExtensionRuntime.compatibility.range(of: "add(api.runtime")
        #expect(pin != nil)
        #expect(first != nil)
        if let pin, let first { #expect(pin.lowerBound < first.lowerBound) }
    }

    /// WebKit stops delivering a worker's events if its API globals are replaced.
    @Test func theCompatibilityScriptKeepsTheGlobals() {
        #expect(ExtensionRuntime.compatibility.contains("['chrome', 'browser']"))
        #expect(ExtensionRuntime.compatibility.contains("configurable: false"))
    }

    /// Runs the compatibility script over a bare `chrome`, and then `expression`.
    private func afterCompatibility(_ chrome: String, _ expression: String) -> JSValue? {
        let context = JSContext()
        context?.evaluateScript("globalThis.chrome = \(chrome);")
        context?.evaluateScript(ExtensionRuntime.compatibility)
        #expect(context?.exception == nil)
        return context?.evaluateScript(expression)
    }

    private static let worker = "{ runtime: { id: 'made-up', getManifest: () => ({ name: 'Made Up', version: '1' }) }, tabs: {}, storage: {} }"

    /// A worker that touches one of these as it starts dies if it isn't there.
    @Test func whatWebKitLeavesOutIsThereForWorkers() {
        let read = """
        [chrome.notifications.onClicked, chrome.idle.onStateChanged, chrome.management.onInstalled, chrome.downloads.onChanged,
         chrome.identity.onSignInChanged, chrome.privacy.services.passwordSavingEnabled.onChange, chrome.tabGroups.onUpdated,
         chrome.storage.managed.onChanged, chrome.declarativeContent.onPageChanged, chrome.webNavigation?.onHistoryStateUpdated]
          .filter(Boolean).every((event) => typeof event.addListener === 'function')
        """
        #expect(afterCompatibility(Self.worker, read)?.toBool() == true)
    }

    @Test func whatsThereIsLeftAlone() {
        let chrome = "{ runtime: { id: 'made-up' }, tabs: {}, notifications: { mine: true } }"
        #expect(afterCompatibility(chrome, "chrome.notifications.mine && !chrome.notifications.create")?.toBool() == true)
    }

    @Test func unsupportedSidePanelIsNotAdvertised() {
        #expect(afterCompatibility(Self.worker, "typeof chrome.sidePanel")?.toString() == "undefined")
        let chrome = "{ runtime: { id: 'made-up' }, tabs: {}, sidePanel: { supported: true } }"
        #expect(afterCompatibility(chrome, "chrome.sidePanel.supported")?.toBool() == true)
    }

    @Test func dynamicScriptsKeepSupportedMatches() {
        let chrome = """
        { runtime: { id: 'made-up' }, tabs: {}, scripting: {
          registerContentScripts: function(scripts, callback) { this.received = scripts; callback?.(); return 17; }
        } }
        """
        let expression = """
        (() => {
          const input = [{ id: 'mixed', matches: ['file://*/*', 'https://*/*'], js: ['content.js'] },
                         { id: 'fileOnly', matches: ['file://*/*'] }];
          let called = false;
          const result = chrome.scripting.registerContentScripts(input, () => { called = true; });
          const received = chrome.scripting.received;
          return called && result === 17 && input[0].matches.length === 2 &&
            received[0].matches.join() === 'https://*/*' && received[0].js[0] === 'content.js' &&
            received[1].matches[0] === 'file://*/*';
        })()
        """
        #expect(afterCompatibility(chrome, expression)?.toBool() == true)
    }

    @Test func standInsCallBackAndAnswer() {
        let run = "let called; chrome.idle.queryState(60, (state) => { called = state; }); called"
        #expect(afterCompatibility(Self.worker, run)?.toString() == "active")
    }

    @Test func aStandInSaysWhoItIs() {
        #expect(afterCompatibility(Self.worker, "chrome.identity.getRedirectURL('done')")?.toString()
            == "https://made-up.chromiumapp.org/done")
    }

    /// A content script gets no more of Chrome than it would there.
    @Test func contentScriptsDontGetTheRest() {
        #expect(afterCompatibility("{ runtime: { id: 'made-up' } }", "'notifications' in chrome")?.toBool() == false)
    }

    /// WebKit keeps it behind a flag, and Proton Pass finds no forms without it.
    @Test func pagesGetRequestIdleCallback() {
        let context = JSContext()
        context?.evaluateScript("globalThis.document = {}; globalThis.setTimeout = (run) => { run(); return 7; }; globalThis.performance = { now: () => 0 };")
        context?.evaluateScript(ExtensionRuntime.idleCallback)
        #expect(context?.exception == nil)
        let run = "let left; requestIdleCallback((deadline) => { left = deadline.timeRemaining(); }); left"
        #expect(context?.evaluateScript(run)?.toInt32() == 50)
    }

    @Test func aWorkerRunsBehindTheCompatibilityScript() throws {
        let (root, source) = try folder(manifest: #"{"name": "Made Up", "background": {"service_worker": "background.js"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ExtensionRuntime.prepare(source, id: "made-up", in: root.appending(path: "runtime")).folder

        #expect(prepared != source)
        #expect(try worker(in: prepared) == ExtensionRuntime.workerFile)
        #expect(try text(ExtensionRuntime.workerFile, in: prepared)
            == "importScripts(\"/\(ExtensionRuntime.compatibilityFile)\", \"/background.js\");\n")
        #expect(try text(ExtensionRuntime.compatibilityFile, in: prepared).contains("onUpdateAvailable"))
        #expect(try text("background.js", in: prepared) == "// the extension's own")
    }

    @Test func pagesAndContentScriptsLoadItToo() throws {
        let (root, source) = try folder(manifest: #"""
        {"background": {"service_worker": "background.js"}, "content_scripts": [
            {"matches": ["<all_urls>"], "js": ["content.js"]},
            {"matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN"},
            {"matches": ["<all_urls>"], "css": ["look.css"]}]}
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"<html><head><style>a{}</style></head><body><script src="popup.js"></script><script src="b.js"></script></body></html>"#.utf8)
            .write(to: source.appending(path: "popup.html"))
        try Data("<html><body>No scripts</body></html>".utf8).write(to: source.appending(path: "plain.html"))
        let prepared = try ExtensionRuntime.prepare(source, id: "made-up", in: root.appending(path: "runtime")).folder

        let data = try Data(contentsOf: prepared.appending(path: "manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scripts = try #require(manifest["content_scripts"] as? [[String: Any]])
        #expect(scripts[0]["js"] as? [String] == [ExtensionRuntime.compatibilityFile, "content.js"])
        #expect(scripts[1]["js"] as? [String] == [ExtensionRuntime.pageCompatibilityFile, "main.js"])
        #expect(scripts[2]["js"] == nil)

        let tag = "<script src=\"/\(ExtensionRuntime.compatibilityFile)\"></script>"
        #expect(try text("popup.html", in: prepared).contains(tag + #"<script src="popup.js">"#))
        #expect(try text("popup.html", in: prepared).components(separatedBy: tag).count == 2)
        #expect(try text("plain.html", in: prepared) == "<html><body>No scripts</body></html>")
    }

    @Test func aModuleWorkerImports() throws {
        let (root, source) = try folder(manifest: #"{"background": {"service_worker": "js/background.js", "type": "module"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ExtensionRuntime.prepare(source, id: "made-up", in: root.appending(path: "runtime")).folder
        #expect(try text(ExtensionRuntime.workerFile, in: prepared)
            == "import \"/\(ExtensionRuntime.compatibilityFile)\";\nimport \"/js/background.js\";\n")
    }

    @Test func nestedClassicWorkersKeepTheirOriginalImportBase() throws {
        let (root, source) = try folder(manifest: #"{"background": {"service_worker": "js/background.js"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ExtensionRuntime.prepare(source, id: "made-up", in: root.appending(path: "runtime")).folder
        let wrapper = try text(ExtensionRuntime.workerFile, in: prepared)
        #expect(wrapper.contains("new URL(\"/js/background.js\", globalThis.location.href)"))
        #expect(wrapper.contains("new URL(url, base).href"))
        #expect(wrapper.contains("importScripts(\"/\(ExtensionRuntime.compatibilityFile)\", \"/js/background.js\")"))
    }

    @Test func theInstalledFolderStaysAsItWas() throws {
        let manifest = #"{"background": {"service_worker": "background.js"}}"#
        let (root, source) = try folder(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ExtensionRuntime.prepare(source, id: "made-up", in: root.appending(path: "runtime"))
        #expect(try text("manifest.json", in: source) == manifest)
        #expect(!FileManager.default.fileExists(atPath: source.appending(path: ExtensionRuntime.workerFile).path))
    }

    /// WebKit reuses a worker's stored scripts until they're forgotten.
    @Test func aChangedWorkerIsReported() throws {
        let (root, source) = try folder(manifest: #"{"version": "1", "background": {"service_worker": "background.js"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "runtime")
        func prepare() throws -> ExtensionRuntime.Prepared { try ExtensionRuntime.prepare(source, id: "made-up", in: runtime) }
        let initial = try prepare()
        #expect(initial.workerChanged)
        // If loading fails, the next attempt still has to invalidate the old worker.
        #expect(try prepare().workerChanged)
        try initial.markLoaded()
        #expect(try !prepare().workerChanged)

        try Data("// updated".utf8).write(to: source.appending(path: "background.js"))
        let updated = try prepare()
        #expect(updated.workerChanged)
        try updated.markLoaded()
        #expect(try !prepare().workerChanged)

        let manifest = #"{"version": "2", "background": {"service_worker": "background.js"}}"#
        try Data(manifest.utf8).write(to: source.appending(path: "manifest.json"))
        #expect(try prepare().workerChanged)

        ExtensionRuntime.discard(id: "made-up", in: runtime)
        #expect(try prepare().workerChanged)
    }

    @Test func nothingToWrapRunsFromWhereItIs() throws {
        let (root, source) = try folder(manifest: #"{"name": "No Worker"}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try ExtensionRuntime.prepare(source, id: "made-up", in: root.appending(path: "runtime")).folder == source)
    }

    @Test func preparingAgainReplacesTheCopy() throws {
        let (root, source) = try folder(manifest: #"{"background": {"service_worker": "background.js"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "runtime")
        _ = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime)
        try Data("// updated".utf8).write(to: source.appending(path: "background.js"))
        let prepared = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime).folder
        #expect(try text("background.js", in: prepared) == "// updated")
    }

    @Test func unchangedRuntimeIsReusedButEditsAndDamageAreRebuilt() throws {
        let (root, source) = try folder(manifest: #"{"background": {"service_worker": "background.js"}}"#)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let runtime = root.appending(path: "runtime")
        let extra = source.appending(path: "extra.js")
        try Data("original".utf8).write(to: extra)
        let first = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime)
        try first.markLoaded()
        let manifest = first.folder.appending(path: "manifest.json")
        let inode = try #require(try files.attributesOfItem(atPath: manifest.path)[.systemFileNumber] as? NSNumber)
        let reused = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime)
        #expect(!reused.workerChanged)
        #expect(try files.attributesOfItem(atPath: manifest.path)[.systemFileNumber] as? NSNumber == inode)

        // A file's mtime can be restored after an edit; ctime still invalidates the copy.
        let oldDate = try #require(try files.attributesOfItem(atPath: extra.path)[.modificationDate] as? Date)
        try Data("modified".utf8).write(to: extra)
        try files.setAttributes([.modificationDate: oldDate], ofItemAtPath: extra.path)
        let updated = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime)
        #expect(try text("extra.js", in: updated.folder) == "modified")
        #expect(!updated.workerChanged)

        let inserted = source.appending(path: "added.js")
        try Data("new".utf8).write(to: inserted)
        let withAdded = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime)
        #expect(try text("added.js", in: withAdded.folder) == "new")
        try files.removeItem(at: inserted)
        let withoutAdded = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime)
        #expect(!files.fileExists(atPath: withoutAdded.folder.appending(path: "added.js").path))

        let generated = withoutAdded.folder.appending(path: ExtensionRuntime.compatibilityFile)
        try Data("damaged".utf8).write(to: generated)
        let repaired = try ExtensionRuntime.prepare(source, id: "made-up", in: runtime)
        #expect(try text(ExtensionRuntime.compatibilityFile, in: repaired.folder) == ExtensionRuntime.compatibility)
        ExtensionRuntime.discard(id: "made-up", in: runtime)
        #expect(!files.fileExists(atPath: runtime.appending(path: "made-up.prepared").path))
    }
}
