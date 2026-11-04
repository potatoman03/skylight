import Foundation

/// `skylight.json` at the root of a package folder.
///
/// ```json
/// {
///   "id": "dev.sophie.quiet-youtube",
///   "name": "Quiet YouTube",
///   "version": "0.1.0",
///   "matches": ["*://*.youtube.com/*"],
///   "styles": ["style.css"],
///   "scripts": ["page.js"],
///   "commands": [{ "id": "hide-shorts", "title": "Hide Shorts" }]
/// }
/// ```
public struct PackageManifest: Codable, Equatable, Sendable {
    public static let fileName = "skylight.json"

    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    /// Match patterns like `*://*.example.com/*` or `<all_urls>`.
    public var matches: [String]
    public var styles: [String]
    public var scripts: [String]
    public var commands: [Command]

    public struct Command: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String?

        public init(id: String, title: String, subtitle: String? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
        }
    }

    public init(id: String, name: String, version: String = "0.1.0", description: String? = nil,
                matches: [String], styles: [String] = [], scripts: [String] = [], commands: [Command] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.matches = matches
        self.styles = styles
        self.scripts = scripts
        self.commands = commands
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        matches = try c.decodeIfPresent([String].self, forKey: .matches) ?? ["<all_urls>"]
        styles = try c.decodeIfPresent([String].self, forKey: .styles) ?? []
        scripts = try c.decodeIfPresent([String].self, forKey: .scripts) ?? []
        commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
    }

    /// Problems that make the manifest unusable.
    public func validate() -> [String] {
        var problems: [String] = []
        if id.isEmpty || !id.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) {
            problems.append("id must be letters, digits, dots, dashes or underscores")
        }
        if matches.isEmpty { problems.append("matches must list at least one pattern") }
        for pattern in matches where MatchPattern(pattern) == nil { problems.append("invalid match pattern: \(pattern)") }
        for file in styles + scripts where file.contains("..") || file.hasPrefix("/") {
            problems.append("file paths must stay inside the package: \(file)")
        }
        return problems
    }
}

/// A package read from disk, with its file contents.
public struct LoadedPackage: Equatable, Sendable, Identifiable {
    public var manifest: PackageManifest
    public var directory: URL
    public var css: String
    public var scripts: [String]
    public var matchers: [MatchPattern]

    public var id: String { manifest.id }

    public func applies(to url: URL) -> Bool { matchers.contains { $0.matches(url) } }
}
