import Foundation

/// A site whose sign-in the New Space sheet can bring into a new profile.
public enum SignInSite: String, CaseIterable, Codable, Identifiable, Sendable {
    case google, github

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .google: "Google"
        case .github: "GitHub"
        }
    }

    /// Where the site keeps its sign-in cookies, subdomains included.
    public var domains: [String] {
        switch self {
        case .google: ["google.com", "youtube.com", "gmail.com"]
        case .github: ["github.com"]
        }
    }

    /// Cookies that exist only while someone is signed in.
    public var signedInCookies: Set<String> {
        switch self {
        case .google: ["SID", "__Secure-1PSID"]
        case .github: ["user_session"]
        }
    }
}

/// What a new Space keeps from the one it starts from. The sheet remembers the last choice.
public struct SpaceSetup: Codable, Equatable, Sendable {
    /// Use the same profile, so everything carries over. The rest applies only when this is false.
    public var sharesEverything: Bool
    /// Copied once, then independent.
    public var sites: Set<SignInSite>
    /// Keep one list of saved passwords with the source profile.
    public var passwords: Bool
    /// Extensions not to copy. Listing the ones left out means a new extension comes along.
    public var skippedExtensions: Set<String>

    public init(sharesEverything: Bool = true, sites: Set<SignInSite> = Set(SignInSite.allCases),
                passwords: Bool = true, skippedExtensions: Set<String> = []) {
        self.sharesEverything = sharesEverything
        self.sites = sites
        self.passwords = passwords
        self.skippedExtensions = skippedExtensions
    }

    private enum CodingKeys: String, CodingKey {
        case sharesEverything, sites, passwords, skippedExtensions
    }

    /// A site this version doesn't know is dropped rather than losing the file it's saved in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sites = try c.decodeIfPresent([String].self, forKey: .sites)
        self.init(sharesEverything: try c.decodeIfPresent(Bool.self, forKey: .sharesEverything) ?? true,
                  sites: sites.map { Set($0.compactMap(SignInSite.init(rawValue:))) } ?? Set(SignInSite.allCases),
                  passwords: try c.decodeIfPresent(Bool.self, forKey: .passwords) ?? true,
                  skippedExtensions: try c.decodeIfPresent(Set<String>.self, forKey: .skippedExtensions) ?? [])
    }
}

/// The New Space sheet, while it's up.
public struct SpaceSetupRequest: Identifiable, Equatable, Sendable {
    /// The existing Space getting its own profile; nil for a new Space.
    public let space: SpaceID?
    /// The Space's name, or the suggested one.
    public let name: String
    /// The Space everything is kept from.
    public let sourceName: String
    public let source: ProfileID
    /// The sites `source` is signed in to.
    public let signedIn: [SignInSite]

    public var id: String { space.map { "\($0)" } ?? "new" }

    public init(space: SpaceID?, name: String, sourceName: String, source: ProfileID, signedIn: [SignInSite]) {
        self.space = space
        self.name = name
        self.sourceName = sourceName
        self.source = source
        self.signedIn = signedIn
    }
}
