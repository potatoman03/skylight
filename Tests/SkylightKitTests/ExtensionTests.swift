import Foundation
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

@Suite struct ExtensionFoldersTests {
    @Test func onlyFoldersChromiumCanLoadAtLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appending(path: "good"), comma = root.appending(path: "a,b"), empty = root.appending(path: "empty")
        for folder in [good, comma, empty] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: good.appending(path: "manifest.json"))
        try Data("{}".utf8).write(to: comma.appending(path: "manifest.json"))
        #expect(ExtensionFolders.launchable([good, comma, empty, root.appending(path: "gone")]) == [good])
    }
}
