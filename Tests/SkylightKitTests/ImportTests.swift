import CommonCrypto
import Foundation
import SkylightCore
@testable import SkylightKit
import SQLite3
import Testing

struct AsideVaultTests {
    static let export = #"""
    {"version":"1.0","exported_at":"2026-11-06T00:00:00.000Z","items":[
      {"category":"001","title":"Example","state":"active","urls":[{"url":"https://example.com/login"},{"url":"https://example.com/other"},{"url":"https://two.example"}],
       "loginFields":[{"designation":"username","value":"me"},{"designation":"password","value":"long-enough-to-have-been-at-risk-of-a-cut"}],"sections":[]},
      {"category":"001","title":"Passkey only","state":"active","urls":[{"url":"https://passkey.example"}],"loginFields":[],"sections":[],"passkeys":[{}]},
      {"category":"001","title":"Binned","state":"trashed","urls":[{"url":"https://old.example"}],
       "loginFields":[{"designation":"password","value":"old"}],"sections":[]},
      {"category":"002","title":"Card","state":"active","loginFields":[],"sections":[{"id":"card-details","fields":[
        {"id":"cardholder","value":{"type":"string","string":"Sam Example"}},
        {"id":"ccnum","value":{"type":"creditCardNumber","creditCardNumber":"4242 4242 4242 4242"}},
        {"id":"expiry","value":{"type":"monthYear","monthYear":203307}}]}]},
      {"category":"004","title":"Me","state":"archived","loginFields":[],"sections":[
        {"id":"name","fields":[{"id":"firstname","value":{"type":"string","string":"Sam"}},{"id":"lastname","value":{"type":"string","string":"Example"}},
                               {"id":"company","value":{"type":"string","string":"Made Up"}}]},
        {"id":"address","fields":[{"id":"address","value":{"type":"address","address":{"street":"1 Way","city":"Town","state":"CA","zip":"94000","country":"us"}}},
                                  {"id":"defphone","value":{"type":"phone","phone":"+14155550100"}}]},
        {"id":"internet","fields":[{"id":"email","value":{"type":"email","email":{"email_address":"sam@example.com"}}}]}]},
      {"category":"003","title":"Note","state":"active","loginFields":[],"sections":[]}]}
    """#

    @Test func loginsCardsAndAddressesComeOut() throws {
        let vault = try AsideVaultExport.read(Data(Self.export.utf8))
        #expect(vault.credentials.map(\.origin) == ["https://example.com", "https://two.example"])
        #expect(vault.credentials.allSatisfy { $0.username == "me" && $0.password.hasPrefix("long-enough") })
        let card = try #require(vault.autofill.cards.first)
        #expect((card.name, card.number, card.month, card.year) == ("Sam Example", "4242424242424242", 7, 2033))
        let address = try #require(vault.autofill.addresses.first)
        #expect((address.name, address.company, address.line1, address.city) == ("Sam Example", "Made Up", "1 Way", "Town"))
        #expect((address.zip, address.phone, address.email) == ("94000", "+14155550100", "sam@example.com"))
    }

    @Test func somethingElseIsRefused() {
        #expect(throws: AsideVaultExport.ReadError.unreadable) { try AsideVaultExport.read(Data("{}".utf8)) }
        #expect(throws: AsideVaultExport.ReadError.unreadable) { try AsideVaultExport.read(Data("nope".utf8)) }
    }

    // The Vault's three CSVs, with the columns its code writes, in that order.
    @Test func itsCSVsAllRead() throws {
        let files = ["category,title,notes,favorite,username,password,url,urls,totp\n001,Site,,0,me,pw,https://a.example,https://a.example,\n002,Card,,0,,,,,",
                     "title,notes,username,password,website,totp\nSite,,me,pw,https://a.example,",
                     "name,url,username,password\nSite,https://a.example,me,pw"]
        for file in files {
            let found = try PasswordCSV.parse(file, source: "CSV")
            #expect(found.map(\.id) == ["https://a.example|me"])
            #expect(found.map(\.password) == ["pw"])
        }
    }
}

struct ChromiumExtensionsTests {
    @Test func onlyWhatYouInstalledAndKeptOn() throws {
        func id(_ letter: Character) -> String { String(repeating: letter, count: 32) }
        let json: [String: Any] = ["extensions": ["settings": [
            id("a"): ["location": 1, "from_webstore": true],
            id("b"): ["location": 5],
            id("c"): ["location": 1, "was_installed_by_default": true],
            id("d"): ["location": 1, "disable_reasons": 1],
            id("e"): ["location": 1, "disable_reasons": [1]],
            id("f"): ["location": 1, "state": 0],
            id("g"): ["location": 1, "disable_reasons": []],
            "not an id": ["location": 1],
        ]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(ChromiumExtensions.storeIDs(in: [data, data]) == [id("a"), id("g")])
    }

    // As Chromium writes them: no `state`, a list of reasons, and `from_webstore` on every entry.
    @Test func readsTheShapeBrowsersWriteNow() throws {
        func id(_ letter: Character) -> String { String(repeating: letter, count: 32) }
        let json: [String: Any] = ["extensions": ["settings": [
            id("a"): ["location": 1, "from_webstore": true, "creation_flags": 9, "disable_reasons": [],
                      "was_installed_by_default": false, "was_installed_by_oem": false],
            id("b"): ["location": 5, "from_webstore": false, "creation_flags": 1, "disable_reasons": []],
            id("c"): ["location": 1, "from_webstore": false, "creation_flags": 1, "disable_reasons": []],
        ]]]
        #expect(ChromiumExtensions.storeIDs(in: [try JSONSerialization.data(withJSONObject: json)]) == [id("a")])
    }

    @Test func aBrokenFileIsNothing() {
        #expect(ChromiumExtensions.storeIDs(in: [Data("nope".utf8)]).isEmpty)
    }
}

struct AutofillTests {
    static let key = "fixture-key"

    func encrypt(_ plain: String) -> [UInt8] {
        let derived = ChromiumPasswordImporter.derivedKey(Self.key)
        return Array("v10".utf8) + ChromiumPasswordImporter.crypt(CCOperation(kCCEncrypt), Array(plain.utf8), key: derived)!
    }

    /// A made-up `Web Data`, in the shape current Chromium writes.
    func makeWebData(tokens: String = "address_type_tokens", cards: [(String, [UInt8])]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "skylight-autofill-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Web Data")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE \(tokens)(guid VARCHAR, type INTEGER, value VARCHAR);
        INSERT INTO \(tokens) VALUES('home', 7, 'Sam Example'), ('home', 77, '1 Example Way
        Floor 2'), ('home', 33, 'Springfield'), ('home', 34, 'CA'), ('home', 35, '90210'),
        ('home', 36, 'US'), ('home', 14, '+15550100000'), ('home', 9, 'sam@example.com'), ('home', 60, 'Example Co');
        CREATE TABLE credit_cards(guid VARCHAR PRIMARY KEY, name_on_card VARCHAR, expiration_month INTEGER,
                                  expiration_year INTEGER, card_number_encrypted BLOB);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for (guid, blob) in cards {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO credit_cards VALUES(?, 'Sam Example', 4, 2031, ?)", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, guid, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(blob.count), transient) }
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return file
    }

    @Test func readsAddressesAndCards() throws {
        let file = try makeWebData(cards: [("visa", encrypt("4242424242424242"))])
        let found = try ChromiumAutofillImporter.read(webData: file, safeStorageKey: Self.key)
        let address = try #require(found.addresses.first)
        #expect(address.name == "Sam Example")
        #expect(address.line1 == "1 Example Way")
        #expect(address.line2 == "Floor 2")
        #expect(address.city == "Springfield")
        #expect(address.zip == "90210")
        #expect(address.phone == "+15550100000")
        #expect(address.company == "Example Co")
        let card = try #require(found.cards.first)
        #expect(card.number == "4242424242424242")
        #expect(card.last4 == "4242")
        #expect(card.brand == "Visa")
        #expect(card.month == 4)
        #expect(card.year == 2031)
    }

    @Test func readsTheOlderAddressTable() throws {
        let file = try makeWebData(tokens: "local_addresses_type_tokens", cards: [])
        #expect(try ChromiumAutofillImporter.read(webData: file, safeStorageKey: Self.key).addresses.count == 1)
    }

    @Test func theWrongKeyGivesNoCards() throws {
        let file = try makeWebData(cards: [("visa", encrypt("4242424242424242"))])
        #expect(try ChromiumAutofillImporter.read(webData: file, safeStorageKey: "wrong").cards.isEmpty)
    }

    @Test func mergingAddsOnlyWhatsNew() {
        var address = AutofillAddress(id: "a")
        address.name = "Sam Example"
        address.line1 = "1 Example Way"
        var same = AutofillAddress(id: "b")
        same.name = "SAM  example"
        same.line1 = "1 example way"
        let card = AutofillCard(id: "c", name: "Sam", number: "4242424242424242", month: 1, year: 2031)
        var data = AutofillData(addresses: [address])
        #expect(data.merge(AutofillData(addresses: [same], cards: [card, card])) == (0, 1))
        #expect(data.cards.count == 1)
    }

    @Test func aListedCardHasNoNumber() {
        let card = AutofillCard(name: "Sam", number: "4242424242424242", month: 1, year: 2031).withoutNumber
        #expect(card.number.isEmpty)
        #expect(card.title == "•••• 4242")
    }

    @Test func fieldsSkipWhatsMissing() {
        var address = AutofillAddress()
        address.name = "Sam Q Example"
        #expect(address.fields == ["name": "Sam Q Example", "given": "Sam", "family": "Example"])
        let card = AutofillCard(name: "", number: "4242424242424242", month: 4, year: 2031)
        #expect(card.fields["cc-exp"] == "04/31")
        #expect(card.fields["cc-exp-year"] == "2031")
        #expect(card.fields["cc-name"] == nil)
    }

    @Test func cardsOnlyGoToSecurePages() {
        func accepts(_ url: String, card: Bool) -> Bool { AutofillScript.accepts(URL(string: url), card: card) }
        #expect(accepts("https://shop.example/", card: true))
        #expect(!accepts("http://shop.example/", card: true))
        #expect(accepts("http://localhost:3000/", card: true))
        #expect(accepts("http://shop.example/", card: false))
        #expect(!accepts("file:///tmp/form.html", card: false))
        #expect(!accepts("skylight://settings", card: true))
        #expect(!AutofillScript.accepts(nil, card: false))
    }

    @Test func theScriptCarriesValuesAsData() {
        let script = AutofillScript.fill(["name": "\"); alert(1); (\""])
        #expect(script.contains(#"\"); alert(1); (\""#))
    }

    @MainActor @Test func storesKeepProfilesApart() throws {
        let store = MemoryAutofillStore()
        let other = ProfileID()
        try store.save(AutofillData(cards: [AutofillCard(name: "", number: "4242424242424242", month: 1, year: 2031)]), in: .standard)
        #expect(try store.load(other).isEmpty)
        #expect(try store.load(.standard).cards.count == 1)
    }
}

@MainActor
struct HistoryTests {
    let url = URL(string: "https://example.com/page")!
    let other = URL(string: "https://www.example.org/")!

    @Test func visitsAddUp() {
        let store = HistoryStore(file: nil)
        store.record(url, title: "Example", in: .standard)
        store.record(url, title: "", in: .standard)
        let entry = store.recent(in: .standard).first
        #expect(entry?.count == 2)
        #expect(entry?.title == "Example")
    }

    @Test func onlyTheWebIsKept() {
        let store = HistoryStore(file: nil)
        store.record(URL(string: "file:///etc/hosts")!, title: "", in: .standard)
        store.record(URL(string: "skylight://settings")!, title: "", in: .standard)
        #expect(store.count(in: .standard) == 0)
    }

    @Test func aSiteYouTypedComesFirst() {
        let store = HistoryStore(file: nil)
        store.add([HistoryEntry(url: URL(string: "https://news.example/github")!, title: "About github", count: 50, last: .now),
                   HistoryEntry(url: URL(string: "https://github.com/")!, title: "GitHub", count: 2, last: .now)], to: .standard)
        #expect(store.suggestions(for: "git", in: .standard).first?.url.host() == "github.com")
    }

    @Test func wildcardsAreJustCharacters() {
        let store = HistoryStore(file: nil)
        store.record(url, title: "Example", in: .standard)
        #expect(store.suggestions(for: "%", in: .standard).isEmpty)
        #expect(store.suggestions(for: "_", in: .standard).isEmpty)
        #expect(store.recent(in: .standard, matching: "%").isEmpty)
    }

    @Test func profilesStayApart() {
        let store = HistoryStore(file: nil)
        let mine = ProfileID()
        store.record(url, title: "", in: mine)
        #expect(store.recent(in: .standard).isEmpty)
        #expect(store.suggestions(for: "example", in: mine).count == 1)
    }

    @Test func importingKeepsTheBiggerNumbers() {
        let store = HistoryStore(file: nil)
        let earlier = Date(timeIntervalSince1970: 1000)
        store.record(url, title: "Here", in: .standard, at: Date(timeIntervalSince1970: 2000))
        let added = store.add([HistoryEntry(url: url, title: "There", count: 9, last: earlier),
                               HistoryEntry(url: other, title: "New", count: 1, last: earlier)], to: .standard)
        #expect(added == 1)
        let entry = store.recent(in: .standard, matching: "example.com").first
        #expect(entry?.count == 9)
        #expect(entry?.title == "Here")
        #expect(entry?.last == Date(timeIntervalSince1970: 2000))
    }

    @Test func clearingAndRemoving() {
        let store = HistoryStore(file: nil)
        store.record(url, title: "", in: .standard)
        store.record(other, title: "", in: .standard)
        store.remove(url, from: .standard)
        #expect(store.count(in: .standard) == 1)
        store.clear(.standard)
        #expect(store.count(in: .standard) == 0)
    }

    @Test func readsChromiumHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "skylight-history-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "History")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        let schema = """
        CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER,
                          typed_count INTEGER DEFAULT 0, last_visit_time INTEGER, hidden INTEGER DEFAULT 0);
        INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES
          ('https://example.com/', 'Example', 3, 13300000000000000, 0),
          ('https://example.org/', 'Newer', 1, 13400000000000000, 0),
          ('https://hidden.example/', 'Frame', 1, 13500000000000000, 1);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let found = try ChromiumHistoryImporter.read(history: file)
        #expect(found.map(\.title) == ["Newer", "Example"])
        #expect(found.last?.count == 3)
    }
}
