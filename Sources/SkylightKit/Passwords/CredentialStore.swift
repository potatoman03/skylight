import Foundation
import Security

/// Where passwords live. Listing never returns secrets; ask for one password at a time.
@MainActor
public protocol CredentialStore: AnyObject {
    /// Every saved credential, without passwords.
    func all() throws -> [Credential]
    /// Credentials for one normalized origin, without passwords.
    func credentials(forOrigin origin: String) throws -> [Credential]
    func password(for credential: Credential) throws -> String
    /// Adds the credential, or replaces the one with the same origin and username.
    func save(_ credential: Credential) throws
    func delete(_ credential: Credential) throws
}

public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case invalidOrigin(String)
    case notFound
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .invalidOrigin(origin): "Not a web address: \(origin)"
        case .notFound: "That password isn't saved."
        case let .keychain(status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}

/// Passwords in the login Keychain, as internet passwords Safari's Passwords app can also see.
///
/// Items are tagged with a fixed description so Skylight only ever lists its own, never the
/// rest of the user's Keychain.
@MainActor
public final class KeychainCredentialStore: CredentialStore {
    static let marker = "Skylight web password"

    public init() {}

    public func all() throws -> [Credential] {
        try list(extra: [:])
    }

    public func credentials(forOrigin origin: String) throws -> [Credential] {
        try list(extra: Self.location(origin)).filter { $0.origin == origin }
    }

    public func password(for credential: Credential) throws -> String {
        var query = try Self.identity(credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CredentialStoreError.notFound }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func save(_ credential: Credential) throws {
        let query = try Self.identity(credential)
        var changes: [String: Any] = [kSecValueData as String: Data(credential.password.utf8)]
        if let source = credential.source { changes[kSecAttrComment as String] = source }
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }

        var item = query.merging(changes) { $1 }
        item[kSecAttrLabel as String] = "Skylight: \(credential.displayHost)"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialStoreError.keychain(added) }
    }

    public func delete(_ credential: Credential) throws {
        let status = SecItemDelete(try Self.identity(credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }

    private func list(extra: [String: Any]) throws -> [Credential] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: Self.marker,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query.merge(extra) { $1 }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw CredentialStoreError.keychain(status) }
        return items.compactMap(Self.credential(from:)).sorted { ($0.displayHost, $0.username) < ($1.displayHost, $1.username) }
    }

    /// Attributes that pick out one origin.
    static func location(_ origin: String) throws -> [String: Any] {
        guard let parts = CredentialOrigin.parts(of: origin) else { throw CredentialStoreError.invalidOrigin(origin) }
        var attributes: [String: Any] = [
            kSecAttrServer as String: parts.host,
            kSecAttrProtocol as String: parts.scheme == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS,
        ]
        if let port = parts.port { attributes[kSecAttrPort as String] = port }
        return attributes
    }

    /// Attributes that pick out one saved credential.
    static func identity(_ credential: Credential) throws -> [String: Any] {
        var query = try location(credential.origin)
        query[kSecClass as String] = kSecClassInternetPassword
        query[kSecAttrDescription as String] = marker
        query[kSecAttrAccount as String] = credential.username
        return query
    }

    static func credential(from item: [String: Any]) -> Credential? {
        guard let host = item[kSecAttrServer as String] as? String else { return nil }
        let proto = item[kSecAttrProtocol as String] as? String
        let scheme = proto == (kSecAttrProtocolHTTP as String) ? "http" : "https"
        let port = (item[kSecAttrPort as String] as? Int).flatMap { $0 == 0 ? nil : ":\($0)" } ?? ""
        return Credential(
            origin: "\(scheme)://\(host)\(port)",
            username: item[kSecAttrAccount as String] as? String ?? "",
            createdAt: item[kSecAttrCreationDate as String] as? Date,
            source: item[kSecAttrComment as String] as? String
        )
    }
}

/// Passwords kept in memory only. For tests and development builds.
@MainActor
public final class MemoryCredentialStore: CredentialStore {
    private var items: [String: Credential] = [:]

    public init(_ credentials: [Credential] = []) {
        for credential in credentials { items[credential.id] = credential }
    }

    public func all() throws -> [Credential] {
        items.values.map(\.redacted).sorted { ($0.displayHost, $0.username) < ($1.displayHost, $1.username) }
    }

    public func credentials(forOrigin origin: String) throws -> [Credential] {
        try all().filter { $0.origin == origin }
    }

    public func password(for credential: Credential) throws -> String {
        guard let saved = items[credential.id] else { throw CredentialStoreError.notFound }
        return saved.password
    }

    public func save(_ credential: Credential) throws {
        guard CredentialOrigin.parts(of: credential.origin) != nil else {
            throw CredentialStoreError.invalidOrigin(credential.origin)
        }
        var credential = credential
        credential.createdAt = credential.createdAt ?? items[credential.id]?.createdAt ?? Date()
        items[credential.id] = credential
    }

    public func delete(_ credential: Credential) throws {
        items[credential.id] = nil
    }
}

extension MemoryCredentialStore {
    /// Made-up logins, so a development run has something to show.
    public static func demo() -> MemoryCredentialStore {
        MemoryCredentialStore([
            Credential(origin: "https://github.com", username: "octo-sky", password: "not-a-real-password-1", source: "Demo"),
            Credential(origin: "https://news.ycombinator.com", username: "skylight", password: "not-a-real-password-2", source: "Demo"),
            Credential(origin: "https://example.com", username: "demo@example.com", password: "not-a-real-password-3", source: "Demo"),
        ])
    }
}
