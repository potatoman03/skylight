import Foundation
import Testing
@testable import SkylightKit

@Suite struct NativeMessagingHostTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "nmh-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func host(_ name: String, in folder: URL, path: String = "/Applications/Vault.app/Contents/MacOS/helper",
                      origins: [String] = ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]) throws {
        let json: [String: Any] = ["name": name, "description": "", "path": path, "type": "stdio", "allowed_origins": origins]
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appending(path: "\(name).json"))
    }

    @Test func linksHostsFromOtherBrowsers() throws {
        let chrome = try folder(), brave = try folder(), mine = try folder().appending(path: "NativeMessagingHosts")
        try host("com.vault.app", in: chrome)
        try host("com.vault.app", in: brave, path: "/elsewhere")
        try host("com.other.app", in: brave)
        let adopted = NativeMessagingHosts.adopt(from: [chrome, brave], into: mine)
        #expect(Set(adopted) == ["com.vault.app.json", "com.other.app.json"])
        // The first browser's wins.
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: mine.appending(path: "com.vault.app.json").path)
        #expect(link == chrome.appending(path: "com.vault.app.json").path)
        // Nothing new the second time.
        #expect(NativeMessagingHosts.adopt(from: [chrome, brave], into: mine).isEmpty)
    }

    @Test func keepsSkylightsOwnAndDropsUninstalled() throws {
        let chrome = try folder(), mine = try folder()
        try host("com.vault.app", in: chrome)
        try host("com.vault.app", in: mine, path: "/mine")
        try host("com.gone.app", in: chrome)
        NativeMessagingHosts.adopt(from: [chrome], into: mine)
        #expect(try String(contentsOf: mine.appending(path: "com.vault.app.json"), encoding: .utf8).contains("/mine"))
        try FileManager.default.removeItem(at: chrome.appending(path: "com.gone.app.json"))
        NativeMessagingHosts.adopt(from: [chrome], into: mine)
        #expect(!FileManager.default.fileExists(atPath: mine.appending(path: "com.gone.app.json").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: mine.appending(path: "com.gone.app.json").path)) == nil)
    }

    @Test func skipsWhatChromiumWouldReject() throws {
        let chrome = try folder(), mine = try folder()
        try host("relative", in: chrome, path: "helper")
        try host("web", in: chrome, origins: ["https://example.com/"])
        try JSONSerialization.data(withJSONObject: ["name": "other", "path": "/x", "type": "stdio", "allowed_origins": ["chrome-extension://a/"]])
            .write(to: chrome.appending(path: "mismatch.json"))
        try Data("not json".utf8).write(to: chrome.appending(path: "broken.json"))
        #expect(NativeMessagingHosts.adopt(from: [chrome], into: mine).isEmpty)
    }
}
