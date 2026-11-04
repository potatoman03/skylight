import Foundation

/// A saved sign-in for one site.
public struct Credential: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Normalized `https://host[:port]`. See `CredentialOrigin`.
    public var origin: String
    public var username: String
    /// Empty when the credential was listed without its secret.
    public var password: String
    public var createdAt: Date?
    /// Where it came from, like "Chrome" or "CSV". Nil for passwords saved in Skylight.
    public var source: String?

    public var id: String { "\(origin)|\(username)" }

    public var displayHost: String { CredentialOrigin.host(of: origin) ?? origin }

    public init(origin: String, username: String, password: String = "", createdAt: Date? = nil, source: String? = nil) {
        self.origin = origin
        self.username = username
        self.password = password
        self.createdAt = createdAt
        self.source = source
    }

    /// The same credential without its password.
    public var redacted: Credential {
        var copy = self
        copy.password = ""
        return copy
    }
}

/// Origins as passwords are keyed: scheme, lowercased host and a non-default port.
public enum CredentialOrigin {
    public static func normalize(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = url.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    public static func normalize(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        if url.scheme == nil, !trimmed.isEmpty, let guessed = URL(string: "https://\(trimmed)") {
            return normalize(guessed)
        }
        return normalize(url)
    }

    /// `example.com` for `https://example.com:8443`.
    public static func host(of origin: String) -> String? {
        URL(string: origin)?.host(percentEncoded: false)
    }

    static func parts(of origin: String) -> (scheme: String, host: String, port: Int?)? {
        guard let url = URL(string: origin), let scheme = url.scheme, let host = url.host(percentEncoded: false) else { return nil }
        return (scheme, host, url.port)
    }
}
