import Foundation
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

    @Test func findsTheDeveloperKeyAmongTheProofs() throws {
        let storeKey = [UInt8](repeating: 7, count: 30)
        let developerKey = Array(0..<40).map(UInt8.init)
        // The signed data names the id; the developer key is the proof that hashes to it.
        let id: [UInt8] = [0x5f, 0xaa, 0x4e, 0xec, 0x36, 0x11, 0x55, 0x68, 0x12, 0xc2, 0xd7, 0x4b, 0x43, 0x7c, 0x8c, 0x49]
        #expect(ExtensionID.from(publicKey: Data(developerKey)) == "fpkkeoomdgbbffgibcmcnheledhmimej")
        let header = field(2, field(1, storeKey) + field(2, [1, 2]))
            + field(2, field(1, developerKey) + field(2, [3, 4]))
            + field(10000, field(1, id))
        let package = try CRXPackage(crx(header: header, archive: Array("PK\u{3}\u{4}zip".utf8)))
        #expect(package.publicKey == Data(developerKey))
        #expect(package.archive == Data("PK\u{3}\u{4}zip".utf8))
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: CRXPackage.Failure.notCRX) { try CRXPackage(Data("PK\u{3}\u{4}not a crx".utf8)) }
        var v2 = [UInt8](crx(header: [], archive: [0]))
        v2[4] = 2
        #expect(throws: CRXPackage.Failure.unsupportedVersion(2)) { try CRXPackage(Data(v2)) }
    }
}
