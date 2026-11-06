import CommonCrypto
import Foundation
import SkylightCore
import SQLite3
import Testing
@testable import SkylightKit

@Suite struct CredentialOriginTests {
    @Test(arguments: [
        ("https://Example.com/login?next=/", "https://example.com"),
        ("https://example.com:443/", "https://example.com"),
        ("http://example.com:80", "http://example.com"),
        ("https://example.com:8443/a", "https://example.com:8443"),
        ("accounts.google.com", "https://accounts.google.com"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(CredentialOrigin.normalize(input) == expected)
    }

    @Test(arguments: ["android://abc@com.example/", "ftp://example.com", "", "file:///etc/passwd"])
    func rejectsNonWeb(input: String) {
        #expect(CredentialOrigin.normalize(input) == nil)
    }

    @Test func idAndHost() {
        let c = Credential(origin: "https://example.com:8443", username: "me")
        #expect(c.id == "https://example.com:8443|me")
        #expect(c.displayHost == "example.com")
    }
}

@Suite struct PasswordCSVTests {
    @Test func chromeExportWithQuotes() throws {
        let csv = "\u{FEFF}name,url,username,password,note\r\n"
            + "example.com,https://example.com/login,alice,\"p,a\"\"ss\nword\",\"a note, with comma\"\r\n"
            + "nothing,android://x@com.app/,bob,secret,\r\n"
            + "blank,https://blank.example,carol,,\r\n"
        let credentials = try PasswordCSV.parse(csv, source: "CSV")
        #expect(credentials.count == 1)
        #expect(credentials[0].origin == "https://example.com")
        #expect(credentials[0].username == "alice")
        #expect(credentials[0].password == "p,a\"ss\nword")
        #expect(credentials[0].source == "CSV")
    }

    @Test func safariHeaders() throws {
        let csv = "Title,URL,Username,Password,Notes,OTPAuth\nGitHub,https://github.com/,octo,hunter2,,\n"
        let credentials = try PasswordCSV.parse(csv, source: "Safari")
        #expect(credentials.map(\.id) == ["https://github.com|octo"])
    }

    @Test func bitwardenHeaders() throws {
        let csv = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
            + ",,login,Site,,,0,\"https://a.example/x,https://b.example\",me@x.com,pw,\n"
        let credentials = try PasswordCSV.parse(csv, source: "Bitwarden")
        #expect(credentials.count == 1)
        #expect(credentials[0].origin == "https://a.example")
        #expect(credentials[0].username == "me@x.com")
        #expect(credentials[0].password == "pw")
    }

    @Test func missingColumns() {
        #expect(throws: PasswordCSV.ParseError.missingColumns) { try PasswordCSV.parse("a,b\n1,2\n", source: "x") }
        #expect(throws: PasswordCSV.ParseError.empty) { try PasswordCSV.parse("", source: "x") }
    }

    @Test func exportRoundTrips() throws {
        let original = [Credential(origin: "https://example.com", username: "a,b", password: "q\"uote\nline")]
        let parsed = try PasswordCSV.parse(PasswordCSV.export(original), source: "CSV")
        #expect(parsed.map(\.username) == ["a,b"])
        #expect(parsed.map(\.password) == ["q\"uote\nline"])
    }
}

@Suite struct ChromiumPasswordImporterTests {
    static let key = "test-key"

    func encrypt(_ plain: [UInt8]) -> [UInt8] {
        let derived = ChromiumPasswordImporter.derivedKey(Self.key)
        return Array("v10".utf8) + ChromiumPasswordImporter.crypt(CCOperation(kCCEncrypt), plain, key: derived)!
    }

    func makeLoginData(version: Int, rows: [(String, String, [UInt8], Int32)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "skylight-logins-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Login Data")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT INTO meta VALUES('version', '\(version)');
        CREATE TABLE logins(origin_url VARCHAR NOT NULL, username_value VARCHAR, password_value BLOB,
                            date_created INTEGER NOT NULL DEFAULT 0, blacklisted_by_user INTEGER NOT NULL DEFAULT 0);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for (origin, user, blob, blocked) in rows {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO logins VALUES(?, ?, ?, 13300000000000000, ?)", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, origin, -1, transient)
            sqlite3_bind_text(statement, 2, user, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_bind_int(statement, 4, blocked)
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return file
    }

    @Test func readsVersion23() throws {
        let file = try makeLoginData(version: 23, rows: [
            ("https://example.com/login", "alice", encrypt(Array("s3cret".utf8)), 0),
            ("https://example.com/other", "alice", encrypt(Array("dupe".utf8)), 0),
            ("https://never.example/", "", [], 1),
            ("android://hash@com.app/", "bob", encrypt(Array("x".utf8)), 0),
        ])
        let credentials = try ChromiumPasswordImporter.read(loginData: file, safeStorageKey: Self.key, source: "Test")
        #expect(credentials.count == 1)
        #expect(credentials[0].origin == "https://example.com")
        #expect(credentials[0].username == "alice")
        #expect(credentials[0].password == "s3cret")
        #expect(credentials[0].source == "Test")
        // 13300000000000000 µs after 1601 is mid-2022.
        let year = Calendar(identifier: .gregorian).component(.year, from: try #require(credentials[0].createdAt))
        #expect(year == 2022)
    }

    @Test func readsVersion24WithHostHash() throws {
        let hash = [UInt8](repeating: 0xAB, count: 32)
        let file = try makeLoginData(version: 24, rows: [
            ("https://new.example/", "me", encrypt(hash + Array("pässword".utf8)), 0),
        ])
        let credentials = try ChromiumPasswordImporter.read(loginData: file, safeStorageKey: Self.key)
        #expect(credentials.map(\.password) == ["pässword"])
    }

    @Test func wrongKeySkipsRows() throws {
        let file = try makeLoginData(version: 23, rows: [("https://example.com", "a", encrypt(Array("pw".utf8)), 0)])
        let credentials = try ChromiumPasswordImporter.read(loginData: file, safeStorageKey: "wrong")
        #expect(credentials.isEmpty)
    }

    @Test func aGoogleAccountsPasswordsComeToo() throws {
        let saved = try makeLoginData(version: 23, rows: [
            ("https://mac.example", "me", encrypt(Array("on this mac".utf8)), 0),
            ("https://both.example", "me", encrypt(Array("old".utf8)), 0),
        ])
        let account = try makeLoginData(version: 23, rows: [
            ("https://google.example", "me", encrypt(Array("in the account".utf8)), 0),
            ("https://both.example", "me", encrypt(Array("new".utf8)), 0),
        ])
        let credentials = try ChromiumPasswordImporter.read(loginFiles: [account, saved], safeStorageKey: Self.key)
        #expect(credentials.map(\.password).sorted() == ["in the account", "new", "on this mac"])
    }

    @Test func aProfileListsOnlyTheFilesItHas() throws {
        let saved = try makeLoginData(version: 23, rows: [])
        var browser = try #require(ChromiumBrowser.all.first)
        browser.profileDirectory = saved.deletingLastPathComponent()
        #expect(browser.loginFiles == [saved])
        try Data(contentsOf: saved).write(to: browser.accountLoginData)
        #expect(browser.loginFiles == [browser.accountLoginData, saved])
    }

    @Test func missingFile() {
        #expect(throws: ChromiumImportError.self) {
            try ChromiumPasswordImporter.read(loginData: URL(fileURLWithPath: "/nonexistent/Login Data"), safeStorageKey: "k")
        }
    }

    @Test func knownBrowsers() {
        let aside = ChromiumBrowser.all.first { $0.id == "aside" }
        #expect(aside?.loginData.path.hasSuffix("Aside/Default/Login Data") == true)
        #expect(aside?.safeStorageServices.first == "Aside Safe Storage")
        let helium = ChromiumBrowser.all.first { $0.id == "helium" }
        #expect(helium?.loginData.path.hasSuffix("net.imput.helium/Default/Login Data") == true)
        #expect(helium?.safeStorageServices == ["Helium Storage Key"])
    }
}

@MainActor
@Suite struct MemoryCredentialStoreTests {
    @MainActor @Test func profilesKeepTheirOwnLogins() throws {
        let work = ProfileID("work")
        let store = MemoryCredentialStore()
        let origin = "https://mail.example"
        try store.save(Credential(origin: origin, username: "jon1", password: "one"))
        try store.save(Credential(origin: origin, username: "jon2", password: "two"))
        try store.save(Credential(origin: origin, username: "jon3", password: "three", profile: work))
        // The same login can live in both.
        try store.save(Credential(origin: origin, username: "jon1", password: "other", profile: work))

        #expect(try store.credentials(forOrigin: origin, in: .standard).map(\.username) == ["jon1", "jon2"])
        #expect(try store.credentials(forOrigin: origin, in: work).map(\.username) == ["jon1", "jon3"])
        #expect(try store.all(in: ProfileID("empty")).isEmpty)

        let personal = try #require(try store.credentials(forOrigin: origin, in: .standard).first)
        let client = try #require(try store.credentials(forOrigin: origin, in: work).first)
        #expect(try store.password(for: personal) == "one")
        #expect(try store.password(for: client) == "other")
        try store.delete(client)
        #expect(try store.password(for: personal) == "one")
    }

    @Test func upsertAndDelete() throws {
        let store = MemoryCredentialStore()
        try store.save(Credential(origin: "https://example.com", username: "a", password: "one"))
        try store.save(Credential(origin: "https://example.com", username: "a", password: "two"))
        try store.save(Credential(origin: "https://other.example", username: "b", password: "three"))

        #expect(try store.all(in: .standard).count == 2)
        #expect(try store.all(in: .standard).allSatisfy { $0.password.isEmpty })
        let listed = try #require(try store.credentials(forOrigin: "https://example.com", in: .standard).first)
        #expect(try store.password(for: listed) == "two")

        try store.delete(listed)
        #expect(try store.credentials(forOrigin: "https://example.com", in: .standard).isEmpty)
        #expect(throws: CredentialStoreError.notFound) { try store.password(for: listed) }
        #expect(throws: CredentialStoreError.self) { try store.save(Credential(origin: "nope", username: "x")) }
    }
}

@Suite struct KeychainProfileTests {
    private let domain = kSecAttrSecurityDomain as String
    private let description = kSecAttrDescription as String

    @MainActor @Test func defaultProfileKeepsTheItemsItAlwaysHad() throws {
        let query = try KeychainCredentialStore.identity(Credential(origin: "https://example.com", username: "a"))
        #expect(query[description] as? String == "Skylight web password")
        #expect(query[domain] == nil)
    }

    @MainActor @Test func otherProfilesAreSeparateKeychainItems() throws {
        let work = ProfileID("work")
        let query = try KeychainCredentialStore.identity(Credential(origin: "https://example.com", username: "a", profile: work))
        #expect(query[description] as? String == "Skylight web password: work")
        // Part of the item's identity, unlike its description.
        #expect(query[domain] as? String == "work")
        let item: [String: Any] = [kSecAttrServer as String: "example.com", kSecAttrAccount as String: "a"]
        #expect(KeychainCredentialStore.credential(from: item, profile: work)?.profile == work)
    }
}

@Suite struct ChromiumCookieImporterTests {
    static let key = "test-key"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Chromium's time for a date, in microseconds since 1601.
    static func stamp(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

    func encrypt(_ plain: String, hash: Bool = false) -> [UInt8] {
        let derived = ChromiumPasswordImporter.derivedKey(Self.key)
        let body = (hash ? [UInt8](repeating: 7, count: 32) : []) + Array(plain.utf8)
        return Array("v10".utf8) + ChromiumPasswordImporter.crypt(CCOperation(kCCEncrypt), body, key: derived)!
    }

    struct Row {
        var host = ".example.com", name = "sid", value = "", path = "/"
        var blob: [UInt8] = []
        var expires: Int64 = 0
        var secure: Int32 = 1, httpOnly: Int32 = 1, sameSite: Int32 = 1
        var partition = ""
    }

    func makeCookies(version: Int, partitioned: Bool = true, rows: [Row]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "skylight-cookies-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Cookies")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE meta(key TEXT, value TEXT);
        INSERT INTO meta VALUES('version', '\(version)');
        CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER,
                             is_secure INTEGER, is_httponly INTEGER, samesite INTEGER\(partitioned ? ", top_frame_site_key TEXT" : ""));
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for row in rows {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?\(partitioned ? ", ?" : ""))", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, row.host, -1, transient)
            sqlite3_bind_text(statement, 2, row.name, -1, transient)
            sqlite3_bind_text(statement, 3, row.value, -1, transient)
            _ = row.blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(row.blob.count), transient) }
            sqlite3_bind_text(statement, 5, row.path, -1, transient)
            sqlite3_bind_int64(statement, 6, row.expires)
            sqlite3_bind_int(statement, 7, row.secure)
            sqlite3_bind_int(statement, 8, row.httpOnly)
            sqlite3_bind_int(statement, 9, row.sameSite)
            if partitioned { sqlite3_bind_text(statement, 10, row.partition, -1, transient) }
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return file
    }

    @Test func readsAndDecryptsCookies() throws {
        let expires = Self.now.addingTimeInterval(3600)
        let file = try makeCookies(version: 24, rows: [
            Row(host: ".example.com", name: "sid", path: "/app", blob: encrypt("sécret", hash: true), expires: Self.stamp(expires)),
            Row(host: "only.example.com", name: "session", blob: encrypt("x", hash: true), secure: 0, httpOnly: 0, sameSite: -1),
        ])
        let cookies = try ChromiumCookieImporter.read(cookies: file, safeStorageKey: Self.key, now: Self.now)
        #expect(cookies.count == 2)
        let sid = try #require(cookies.first { $0.name == "sid" })
        #expect(sid.value == "sécret")
        #expect(sid.domain == ".example.com")
        #expect(sid.host == "example.com")
        #expect(sid.path == "/app")
        #expect(sid.isSecure && sid.isHTTPOnly)
        #expect(sid.sameSite == .lax)
        #expect(abs(sid.expires!.timeIntervalSince(expires)) < 1)
        let session = try #require(cookies.first { $0.name == "session" })
        #expect(session.expires == nil)
        #expect(session.sameSite == .unspecified)
        #expect(!session.isSecure && !session.isHTTPOnly)
    }

    @Test func olderDatabasesHaveNoHostHash() throws {
        let file = try makeCookies(version: 23, partitioned: false, rows: [Row(blob: encrypt("value"))])
        let cookies = try ChromiumCookieImporter.read(cookies: file, safeStorageKey: Self.key, now: Self.now)
        #expect(cookies.map(\.value) == ["value"])
    }

    @Test func plainValuesComeAcross() throws {
        let file = try makeCookies(version: 24, rows: [Row(value: "plain")])
        let cookies = try ChromiumCookieImporter.read(cookies: file, safeStorageKey: Self.key, now: Self.now)
        #expect(cookies.map(\.value) == ["plain"])
    }

    @Test func expiredAndPartitionedCookiesAreLeft() throws {
        let file = try makeCookies(version: 24, rows: [
            Row(name: "old", blob: encrypt("a", hash: true), expires: Self.stamp(Self.now.addingTimeInterval(-1))),
            Row(name: "embedded", blob: encrypt("b", hash: true), partition: "https://other.example"),
            Row(name: "kept", blob: encrypt("c", hash: true)),
        ])
        let cookies = try ChromiumCookieImporter.read(cookies: file, safeStorageKey: Self.key, now: Self.now)
        #expect(cookies.map(\.name) == ["kept"])
    }

    @Test func aWrongKeyDropsRowsQuietly() throws {
        let file = try makeCookies(version: 24, rows: [Row(blob: encrypt("value", hash: true))])
        #expect(try ChromiumCookieImporter.read(cookies: file, safeStorageKey: "wrong", now: Self.now).isEmpty)
    }

    @Test func aMissingFileIsAnError() {
        #expect(throws: ChromiumImportError.self) {
            try ChromiumCookieImporter.read(cookies: URL(fileURLWithPath: "/nonexistent/Cookies"), safeStorageKey: "k")
        }
    }

    @Test func anotherProfileIsBesideTheDefault() {
        let arc = ChromiumBrowser(id: "arc", name: "Arc", profileDirectory: URL(fileURLWithPath: "/x/Arc/User Data/Default"),
                                  safeStorageServices: ["Arc Safe Storage"], bundleIDs: [])
        #expect(arc.localState.path == "/x/Arc/User Data/Local State")
        #expect(arc.profile("Profile 2").loginData.path == "/x/Arc/User Data/Profile 2/Login Data")
        #expect(arc.profile("Profile 2").safeStorageServices == ["Arc Safe Storage"])
    }

    @Test func newerProfilesKeepCookiesInNetwork() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "skylight-profile-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appending(path: "Network"), withIntermediateDirectories: true)
        let browser = ChromiumBrowser(id: "t", name: "T", profileDirectory: dir, safeStorageServices: [], bundleIDs: [])
        #expect(browser.cookies.lastPathComponent == "Cookies" && !browser.cookies.path.contains("/Network/"))
        FileManager.default.createFile(atPath: dir.appending(path: "Network/Cookies").path, contents: Data())
        #expect(browser.cookies.path.hasSuffix("Network/Cookies"))
    }
}
