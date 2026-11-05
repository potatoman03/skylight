import Foundation

/// A cookie on its way into a profile. Carries a live sign-in, so never log or show its value.
public struct WebCookie: Sendable, Equatable {
    public enum SameSite: Int, Sendable {
        case unspecified, none, lax, strict
    }

    public var name: String
    public var value: String
    /// As a browser stores it: `.example.com` for a whole domain, `example.com` for one host.
    public var domain: String
    public var path: String
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    /// Nil for a cookie that lasts as long as the session.
    public var expires: Date?
    public var sameSite: SameSite

    public init(name: String, value: String, domain: String, path: String = "/", isSecure: Bool = false,
                isHTTPOnly: Bool = false, expires: Date? = nil, sameSite: SameSite = .unspecified) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expires = expires
        self.sameSite = sameSite
    }

    /// The site, for counting them.
    public var host: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }
}
