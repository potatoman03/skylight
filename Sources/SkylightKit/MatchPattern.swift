import Foundation

/// A Chrome-extension-style URL match pattern: `<scheme>://<host><path>`.
///
/// - `<all_urls>` matches http, https and file URLs.
/// - Scheme `*` matches http and https.
/// - Host `*.example.com` matches example.com and its subdomains; `*` matches any host.
/// - Path `*` matches any run of characters.
public struct MatchPattern: Equatable, Sendable, CustomStringConvertible {
    public let pattern: String
    /// A regular expression valid in both NSRegularExpression and JavaScript.
    public let regexSource: String

    public var description: String { pattern }

    public init?(_ pattern: String) {
        self.pattern = pattern
        if pattern == "<all_urls>" {
            regexSource = "^(https?|file)://.*$"
            return
        }
        guard let schemeEnd = pattern.range(of: "://") else { return nil }
        let scheme = String(pattern[..<schemeEnd.lowerBound])
        let rest = pattern[schemeEnd.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = String(rest[..<slash])
        let path = slash < rest.endIndex ? String(rest[slash...]) : "/*"

        let schemeRegex: String
        switch scheme {
        case "*": schemeRegex = "https?"
        case "http", "https", "file": schemeRegex = scheme
        default: return nil
        }

        let hostRegex: String
        if host == "*" {
            hostRegex = "[^/]*"
        } else if host.hasPrefix("*.") {
            let base = Self.escape(String(host.dropFirst(2)))
            hostRegex = "([^/]*\\.)?\(base)(:[0-9]+)?"
        } else if host.contains("*") {
            return nil
        } else if scheme == "file" {
            hostRegex = ""
        } else {
            guard !host.isEmpty else { return nil }
            hostRegex = "\(Self.escape(host))(:[0-9]+)?"
        }

        let pathRegex = path.split(separator: "*", omittingEmptySubsequences: false)
            .map { Self.escape(String($0)) }
            .joined(separator: ".*")
        regexSource = "^\(schemeRegex)://\(hostRegex)\(pathRegex)$"
    }

    public func matches(_ url: URL) -> Bool {
        let s = url.absoluteString
        guard let regex = try? NSRegularExpression(pattern: regexSource, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `/` stays unescaped: ICU rejects `\/`, and `new RegExp` doesn't need it.
    private static func escape(_ s: String) -> String {
        NSRegularExpression.escapedPattern(for: s)
    }
}
