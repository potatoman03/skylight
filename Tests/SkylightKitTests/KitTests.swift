import Foundation
import Testing
@testable import SkylightKit

@Suite struct MatchPatternTests {
    @Test(arguments: [
        ("<all_urls>", "https://anything.example/x", true),
        ("*://*.github.com/*", "https://github.com/a/b", true),
        ("*://*.github.com/*", "https://gist.github.com/x", true),
        ("*://*.github.com/*", "https://notgithub.com/", false),
        ("https://example.com/docs/*", "https://example.com/docs/a", true),
        ("https://example.com/docs/*", "http://example.com/docs/a", false),
        ("https://example.com/docs/*", "https://example.com/blog", false),
    ])
    func matching(pattern: String, url: String, expected: Bool) throws {
        let matcher = try #require(MatchPattern(pattern))
        #expect(matcher.matches(URL(string: url)!) == expected)
    }

    @Test func regexWorksInJavaScriptToo() throws {
        // The same source is handed to `new RegExp` in pages; keep it free of Swift-only syntax.
        let source = try #require(MatchPattern("*://*.github.com/*")).regexSource
        #expect(!source.contains("(?<"))
    }
}

@Suite struct PackageLoaderTests {
    func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "skylight-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func loadsValidPackagesAndReportsBrokenOnes() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"{"id":"dev.notes","name":"Notes","matches":["*://*.example.com/*"],"styles":["s.css"],"scripts":["p.js"],"commands":[{"id":"add","title":"Add note"}]}"#,
                  dir.appending(path: "notes/skylight.json"))
        try write("body{color:red}", dir.appending(path: "notes/s.css"))
        try write("skylight.command('add', () => 1)", dir.appending(path: "notes/p.js"))
        try write(#"{"id":"broken","name":"Broken","scripts":["missing.js"]}"#, dir.appending(path: "broken/skylight.json"))
        try FileManager.default.createDirectory(at: dir.appending(path: "empty"), withIntermediateDirectories: true)

        let report = PackageLoader(directory: dir).load()
        #expect(report.packages.map(\.id) == ["dev.notes"])
        #expect(report.packages[0].css == "body{color:red}")
        #expect(report.packages[0].applies(to: URL(string: "https://www.example.com/a")!))
        #expect(report.failures.keys.sorted() == ["broken", "empty"])
    }

    @Test func boostTemplateCreatesLoadablePackage() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try BoostTemplate.create(forHost: "www.news.example", in: dir)
        #expect(folder.lastPathComponent == "boost-news-example")
        let pkg = try PackageLoader(directory: dir).loadPackage(at: folder).get()
        #expect(pkg.id == "boost.news-example")
        #expect(pkg.applies(to: URL(string: "https://news.example/today")!))
        #expect(try BoostTemplate.create(forHost: "news.example", in: dir).lastPathComponent == "boost-news-example-2")
    }

    @Test func scriptsWrapEachPackageSeparately() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try BoostTemplate.create(forHost: "a.example", in: dir)
        let pkg = try PackageLoader(directory: dir).loadPackage(at: folder).get()
        let scripts = PackageScripts.scripts(for: [pkg])
        #expect(scripts.count == 2)
        #expect(scripts[0] == PackageScripts.runtime)
        #expect(scripts[1].contains("__skylightPackages.define("))
        #expect(scripts[1].contains("\"boost.a-example\""))
    }

    @Test func manifestValidation() {
        let bad = PackageManifest(id: "", name: "", matches: [], styles: [], scripts: [])
        #expect(!bad.validate().isEmpty)
        #expect(PackageManifest(id: "a.b", name: "A", matches: ["<all_urls>"], styles: [], scripts: []).validate().isEmpty)
    }
}

@Suite struct KitPerformanceTests {
    @Test func matchingURLs() throws {
        let patterns = (0..<50).compactMap { MatchPattern("*://*.site\($0).example/*") }
        let urls = (0..<2_000).map { URL(string: "https://www.site\($0 % 100).example/page/\($0)")! }
        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for url in urls { for pattern in patterns where pattern.matches(url) { hits += 1 } }
        }
        print("BENCH match 50 patterns × 2,000 URLs: \(elapsed) total, \(elapsed / 100_000) each")
        #expect(hits == 1_000)
    }
}
