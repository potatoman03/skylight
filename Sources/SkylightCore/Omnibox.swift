import Foundation

/// Turns what the user typed into a URL: an address when it looks like one, a search otherwise.
public struct Omnibox: Sendable {
    /// `%s` is replaced by the percent-encoded query.
    public var searchTemplate: String

    public init(searchTemplate: String = "https://www.google.com/search?q=%s") {
        self.searchTemplate = searchTemplate
    }

    public enum Interpretation: Equatable, Sendable {
        case address(URL)
        case search(String, URL)

        public var url: URL {
            switch self {
            case let .address(u), let .search(_, u): u
            }
        }

        /// A page on the web, not a local file or one of the browser's own.
        public var isWeb: Bool { ["http", "https"].contains(url.scheme?.lowercased()) }
    }

    private static let schemes: Set<String> = ["http", "https", "file", "about", "chrome", "data", "view-source", "skylight"]

    public func interpret(_ raw: String) -> Interpretation? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let scheme = input.split(separator: ":", maxSplits: 1).first.map({ $0.lowercased() }),
           Self.schemes.contains(scheme), input.contains(":"), let url = URL(string: input) {
            return .address(url)
        }

        if !input.contains(where: \.isWhitespace), let url = addressURL(for: input) {
            return .address(url)
        }

        return searchURL(for: input).map { .search(input, $0) }
    }

    /// The address as you'd type it, without `https://` or a lone `/`, if typing that leads back.
    public func short(_ url: URL) -> String {
        guard let scheme = url.scheme, scheme == "https" || scheme == "http" else { return url.absoluteString }
        var short = String(url.absoluteString.dropFirst(scheme.count + 3))
        if url.path() == "/", url.query() == nil, url.fragment() == nil { short.removeLast() }
        if case let .address(typed) = interpret(short), typed.scheme == scheme { return short }
        return url.absoluteString
    }

    public func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: encoded))
    }

    /// `example.com`, `localhost:3000/x`, `192.168.1.2`, `my.site/path?q=1`.
    private func addressURL(for input: String) -> URL? {
        let hostPart = input.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? input
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let isLocal = host == "localhost" || host.hasSuffix(".localhost") || isIPv4(host)
        let looksLikeDomain = host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
            && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
            && (host.split(separator: ".").last.map { $0.count >= 2 && $0.allSatisfy(\.isLetter) } ?? false)
        guard isLocal || looksLikeDomain else { return nil }
        return URL(string: (isLocal ? "http://" : "https://") + input)
    }

    private func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
