import CommonCrypto
import Foundation
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

    @Test func missingFile() {
        #expect(throws: ChromiumImportError.self) {
            try ChromiumPasswordImporter.read(loginData: URL(fileURLWithPath: "/nonexistent/Login Data"), safeStorageKey: "k")
        }
    }

    @Test func knownBrowsers() {
        let aside = ChromiumBrowser.all.first { $0.id == "aside" }
        #expect(aside?.loginData.path.hasSuffix("Aside/Default/Login Data") == true)
        #expect(aside?.safeStorageServices.first == "Aside Safe Storage")
    }
}

@MainActor
@Suite struct MemoryCredentialStoreTests {
    @Test func upsertAndDelete() throws {
        let store = MemoryCredentialStore()
        try store.save(Credential(origin: "https://example.com", username: "a", password: "one"))
        try store.save(Credential(origin: "https://example.com", username: "a", password: "two"))
        try store.save(Credential(origin: "https://other.example", username: "b", password: "three"))

        #expect(try store.all().count == 2)
        #expect(try store.all().allSatisfy { $0.password.isEmpty })
        let listed = try #require(try store.credentials(forOrigin: "https://example.com").first)
        #expect(try store.password(for: listed) == "two")

        try store.delete(listed)
        #expect(try store.credentials(forOrigin: "https://example.com").isEmpty)
        #expect(throws: CredentialStoreError.notFound) { try store.password(for: listed) }
        #expect(throws: CredentialStoreError.self) { try store.save(Credential(origin: "nope", username: "x")) }
    }
}
