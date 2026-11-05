import CommonCrypto
import Foundation
import Security
import SkylightCore
import SQLite3

/// A Chromium-based browser installed on this Mac, and where its default profile keeps things.
public struct ChromiumBrowser: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var profileDirectory: URL
    /// Keychain services that may hold the key Chromium encrypts passwords with, tried in order.
    public var safeStorageServices: [String]
    public var bundleIDs: [String]

    public init(id: String, name: String, profileDirectory: URL, safeStorageServices: [String], bundleIDs: [String]) {
        self.id = id
        self.name = name
        self.profileDirectory = profileDirectory
        self.safeStorageServices = safeStorageServices
        self.bundleIDs = bundleIDs
    }

    public var loginData: URL { profileDirectory.appending(path: "Login Data") }
    public var bookmarks: URL { profileDirectory.appending(path: "Bookmarks") }
    /// Newer versions moved this file into `Network`.
    public var cookies: URL {
        let moved = profileDirectory.appending(path: "Network/Cookies")
        return FileManager.default.fileExists(atPath: moved.path) ? moved : profileDirectory.appending(path: "Cookies")
    }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: profileDirectory.path) }
    /// Beside the profiles: what the browser calls each one.
    public var localState: URL { profileDirectory.deletingLastPathComponent().appending(path: "Local State") }

    /// The same browser, looking at another of its profiles.
    public func profile(_ folder: String) -> ChromiumBrowser {
        var browser = self
        browser.profileDirectory = profileDirectory.deletingLastPathComponent().appending(path: folder)
        return browser
    }

    public static let all: [ChromiumBrowser] = {
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        func browser(_ id: String, _ name: String, _ path: String, _ services: [String], _ bundles: [String]) -> ChromiumBrowser {
            ChromiumBrowser(id: id, name: name, profileDirectory: support.appending(path: path), safeStorageServices: services, bundleIDs: bundles)
        }
        return [
            browser("aside", "Aside", "Aside/Default",
                    ["Aside Safe Storage", "Aside Browser Safe Storage", "Chromium Safe Storage"], ["at.studio.AsideBrowser"]),
            browser("arc", "Arc", "Arc/User Data/Default", ["Arc Safe Storage"], ["company.thebrowser.Browser"]),
            browser("dia", "Dia", "Dia/User Data/Default", ["Dia Safe Storage"], ["company.thebrowser.dia"]),
            browser("chrome", "Chrome", "Google/Chrome/Default", ["Chrome Safe Storage"], ["com.google.Chrome"]),
            browser("brave", "Brave", "BraveSoftware/Brave-Browser/Default", ["Brave Safe Storage"], ["com.brave.Browser"]),
            browser("edge", "Edge", "Microsoft Edge/Default", ["Microsoft Edge Safe Storage"], ["com.microsoft.edgemac"]),
            browser("vivaldi", "Vivaldi", "Vivaldi/Default", ["Vivaldi Safe Storage"], ["com.vivaldi.Vivaldi"]),
            browser("opera", "Opera", "com.operasoftware.Opera", ["Opera Safe Storage"], ["com.operasoftware.Opera"]),
            browser("chromium", "Chromium", "Chromium/Default", ["Chromium Safe Storage"], ["org.chromium.Chromium"]),
        ]
    }()

    public static var installed: [ChromiumBrowser] { all.filter(\.isInstalled) }
}

public enum ChromiumImportError: Error, LocalizedError, Equatable {
    case missingFile(String)
    case database(String)
    case noSafeStorageKey(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .missingFile(path): "Couldn't find \(path)."
        case let .database(message): "Couldn't read the passwords database: \(message)"
        case let .noSafeStorageKey(browser): "Couldn't find \(browser)'s password key in the Keychain."
        case let .keychain(status):
            status == errSecUserCanceled || status == errSecAuthFailed
                ? "Keychain access was declined."
                : (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}

/// Reads saved passwords from a Chromium profile's `Login Data` on macOS.
public enum ChromiumPasswordImporter {
    /// Reads and decrypts every saved login. Rows that fail to decrypt are skipped.
    public static func read(loginData: URL, safeStorageKey: String, source: String? = nil) throws -> [Credential] {
        try withCopy(of: loginData) { db in try logins(in: db, safeStorageKey: safeStorageKey, source: source) }
    }

    private static func logins(in db: OpaquePointer?, safeStorageKey: String, source: String?) throws -> [Credential] {
        let version = Int(try scalar(db, "SELECT value FROM meta WHERE key = 'version'") ?? "0") ?? 0
        let key = derivedKey(safeStorageKey)

        var statement: OpaquePointer?
        let sql = "SELECT origin_url, username_value, password_value, date_created FROM logins WHERE blacklisted_by_user = 0"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ChromiumImportError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var found: [Credential] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let originText = text(statement, 0), let origin = CredentialOrigin.normalize(originText) else { continue }
            let username = text(statement, 1) ?? ""
            let blob = data(statement, 2)
            guard let password = decrypt(blob, key: key, stripsHostHash: version >= 24), !password.isEmpty else { continue }
            let created = sqlite3_column_int64(statement, 3)
            found.append(Credential(origin: origin, username: username, password: password,
                                    createdAt: created > 0 ? chromiumDate(created) : nil, source: source))
        }
        // Chromium can keep one login per form; keep the first per origin and username.
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// The browser's password key from the Keychain. macOS asks the user to allow this.
    public static func safeStorageKey(service: String, account: String? = nil) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ChromiumImportError.noSafeStorageKey(service) }
        guard status == errSecSuccess, let data = result as? Data else { throw ChromiumImportError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Tries each of the browser's Keychain services.
    public static func safeStorageKey(for browser: ChromiumBrowser) throws -> String {
        for service in browser.safeStorageServices {
            do {
                return try safeStorageKey(service: service)
            } catch ChromiumImportError.noSafeStorageKey {
                continue
            }
        }
        throw ChromiumImportError.noSafeStorageKey(browser.name)
    }

    /// Reads the browser's passwords.
    public static func read(_ browser: ChromiumBrowser) throws -> [Credential] {
        try read(loginData: browser.loginData, safeStorageKey: safeStorageKey(for: browser), source: browser.name)
    }

    /// Reads the passwords and cookies of a browser's profiles, in order, with one Keychain prompt
    /// for all of them. Either can be missing: a profile that has never saved a password has no
    /// `Login Data`.
    public static func readSignIns(_ profiles: [ChromiumBrowser]) throws -> [(credentials: [Credential], cookies: [WebCookie])] {
        guard let first = profiles.first else { return [] }
        let key = try safeStorageKey(for: first)
        let files = FileManager.default
        return try profiles.map { browser in
            (files.fileExists(atPath: browser.loginData.path) ? try read(loginData: browser.loginData, safeStorageKey: key, source: browser.name) : [],
             files.fileExists(atPath: browser.cookies.path) ? try ChromiumCookieImporter.read(cookies: browser.cookies, safeStorageKey: key) : [])
        }
    }

    // MARK: - Crypto

    static let salt = Array("saltysalt".utf8)
    static let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)

    /// PBKDF2-HMAC-SHA1, 1003 rounds, 16 bytes: Chromium's macOS key derivation.
    static func derivedKey(_ password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let bytes = Array(password.utf8)
        _ = bytes.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 bytes.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 &key, key.count)
        }
        return key
    }

    /// Decrypts a `v10` value. Newer databases (version 24+) put a SHA-256 of the domain first.
    static func decrypt(_ blob: [UInt8], key: [UInt8], stripsHostHash: Bool) -> String? {
        guard blob.count > 3, blob[0..<3] == Array("v10".utf8)[...] else {
            // Very old profiles stored plain text.
            return blob.isEmpty ? nil : String(bytes: blob, encoding: .utf8)
        }
        guard var plain = crypt(CCOperation(kCCDecrypt), Array(blob.dropFirst(3)), key: key) else { return nil }
        if stripsHostHash {
            guard plain.count >= 32 else { return nil }
            plain.removeFirst(32)
        }
        return String(bytes: plain, encoding: .utf8)
    }

    static func crypt(_ operation: CCOperation, _ input: [UInt8], key: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }

    /// Chromium times are microseconds since 1601-01-01 UTC.
    static func chromiumDate(_ micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    // MARK: - SQLite

    /// Opens a copy of a Chromium database: the browser may hold a lock on the live file.
    static func withCopy<T>(of file: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ChromiumImportError.missingFile(file.path)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "skylight-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        for suffix in ["-journal", "-wal", "-shm"] {
            let side = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ChromiumImportError.database(message)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    static func scalar(_ db: OpaquePointer?, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    static func data(_ statement: OpaquePointer?, _ column: Int32) -> [UInt8] {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return [] }
        return Array(UnsafeRawBufferPointer(start: bytes, count: count))
    }
}
