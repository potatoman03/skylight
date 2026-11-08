import Foundation
import Testing
@testable import SkylightCore

/// Writes the files Chromium's database leaves behind, byte for byte, with made-up groups.
private enum Fixture {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        return out + [UInt8(value)]
    }

    static func number(_ field: UInt64, _ value: Int64) -> [UInt8] {
        varint(field << 3) + varint(UInt64(bitPattern: value))
    }

    static func string(_ field: UInt64, _ value: [UInt8]) -> [UInt8] {
        varint(field << 3 | 2) + varint(UInt64(value.count)) + value
    }

    static func string(_ field: UInt64, _ value: String) -> [UInt8] { string(field, Array(value.utf8)) }

    static func group(_ id: String, _ title: String, order: Int64, wrapped: Bool = true) -> [UInt8] {
        let group = string(2, title) + number(3, 2) + number(4, order)
        return specifics(id, 4, group, wrapped: wrapped)
    }

    static func tab(_ id: String, in group: String, _ url: String, _ title: String = "", at position: Int64 = 0, wrapped: Bool = true) -> [UInt8] {
        let tab = string(1, group) + number(2, position) + string(3, url) + string(4, title)
        return specifics(id, 5, tab, wrapped: wrapped)
    }

    static func specifics(_ id: String, _ field: UInt64, _ body: [UInt8], wrapped: Bool) -> [UInt8] {
        let specifics = string(1, id) + number(2, 13_000_000) + string(field, body)
        return wrapped ? number(1, 1) + string(2, specifics) : specifics
    }

    static func key(_ id: String) -> [UInt8] { Array("saved_tab_group-dt-\(id)".utf8) }

    /// A write batch in one log record.
    static func log(from sequence: UInt64, _ writes: [(key: [UInt8], value: [UInt8]?)]) -> Data {
        var batch = withUnsafeBytes(of: sequence.littleEndian, Array.init) + withUnsafeBytes(of: UInt32(writes.count).littleEndian, Array.init)
        for write in writes {
            batch += [write.value == nil ? 0 : 1] + varint(UInt64(write.key.count)) + write.key
            if let value = write.value { batch += varint(UInt64(value.count)) + value }
        }
        return Data([0, 0, 0, 0, UInt8(batch.count & 0xFF), UInt8(batch.count >> 8), 1] + batch)
    }

    static func block(_ entries: [(key: [UInt8], value: [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        for entry in entries {
            out += varint(0) + varint(UInt64(entry.key.count)) + varint(UInt64(entry.value.count)) + entry.key + entry.value
        }
        return out + [0, 0, 0, 0, 1, 0, 0, 0]
    }

    /// Snappy holding one literal run.
    static func snappy(_ bytes: [UInt8]) -> [UInt8] {
        let last = bytes.count - 1
        return varint(UInt64(bytes.count)) + [61 << 2, UInt8(last & 0xFF), UInt8(last >> 8)] + bytes
    }

    static func table(_ records: [(key: [UInt8], sequence: UInt64, value: [UInt8]?)], compressed: Bool) -> Data {
        let data = block(records.map { record in
            let tag = record.sequence << 8 | (record.value == nil ? 0 : 1)
            return (record.key + withUnsafeBytes(of: tag.littleEndian, Array.init), record.value ?? [])
        })
        let stored = compressed ? snappy(data) : data
        var file = stored + [compressed ? 1 : 0, 0, 0, 0, 0]
        let indexAt = file.count
        let index = block([(Array("z".utf8), varint(0) + varint(UInt64(stored.count)))])
        file += index + [0, 0, 0, 0, 0]
        var footer = varint(0) + varint(0) + varint(UInt64(indexAt)) + varint(UInt64(index.count))
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        footer += [0x57, 0xFB, 0x80, 0x8B, 0x24, 0x75, 0x47, 0xDB]
        return Data(file + footer)
    }
}

@Suite struct TabGroupTests {
    @Test func groupColorsBecomeFolderColors() {
        #expect(FolderColor(chromium: 0) == nil)
        #expect(FolderColor(chromium: 1) == .grey)
        #expect(FolderColor(chromium: 2) == .blue)
        #expect(FolderColor(chromium: 9) == .orange)
        #expect(FolderColor(chromium: 10) == nil)
    }

    @Test func groupsComeOutInTheOrderTheBrowserShows() {
        let log = Fixture.log(from: 10, [
            (Fixture.key("b"), Fixture.group("b", "Second", order: 1)),
            (Fixture.key("a"), Fixture.group("a", "First", order: 0)),
            (Fixture.key("t1"), Fixture.tab("t1", in: "a", "https://one.example/", "One", at: 1)),
            (Fixture.key("t2"), Fixture.tab("t2", in: "a", "https://two.example/", "Two", at: 0)),
            (Fixture.key("t3"), Fixture.tab("t3", in: "b", "https://three.example/page")),
            (Fixture.key("t4"), Fixture.tab("t4", in: "b", "aside://settings/", "Internal")),
            (Array("passwords-dt-x".utf8), Array("not a group".utf8)),
        ])
        let folders = ChromiumTabGroups.read(tables: [], logs: [log])
        #expect(folders.map(\.name) == ["First", "Second"])
        #expect(folders.map(\.color) == [.blue, .blue])
        #expect(folders[0].links.map(\.title) == ["Two", "One"])
        #expect(folders[1].links.map(\.title) == ["three.example"])
    }

    @Test func aDeletedGroupAndItsTabsStayGone() {
        let table = Fixture.table([
            (Fixture.key("gone"), 5, Fixture.group("gone", "Deleted", order: 0)),
            (Fixture.key("kept"), 6, Fixture.group("kept", "Old name", order: 1)),
            (Fixture.key("t1"), 7, Fixture.tab("t1", in: "gone", "https://gone.example/")),
            (Fixture.key("t2"), 8, Fixture.tab("t2", in: "kept", "https://kept.example/")),
        ], compressed: false)
        let log = Fixture.log(from: 20, [
            (Fixture.key("gone"), nil),
            (Fixture.key("kept"), Fixture.group("kept", "New name", order: 1)),
        ])
        let folders = ChromiumTabGroups.read(tables: [table], logs: [log])
        #expect(folders.map(\.name) == ["New name"])
        #expect(folders[0].links.map { $0.url.host() } == ["kept.example"])
    }

    @Test func theOlderFormatAndTheAccountStoreRead() {
        let log = Fixture.log(from: 1, [
            (Array("A-saved_tab_group-dt-g".utf8), Fixture.group("g", "Synced", order: 0, wrapped: false)),
            (Array("A-saved_tab_group-dt-t".utf8), Fixture.tab("t", in: "g", "https://example.com/", wrapped: false)),
        ])
        let folders = ChromiumTabGroups.read(tables: [], logs: [log])
        #expect(folders.map(\.name) == ["Synced"])
        #expect(folders[0].links.count == 1)
    }

    @Test func aCompressedTableReads() {
        let table = Fixture.table([(Fixture.key("g"), 1, Array("value".utf8))], compressed: true)
        let found = LevelDB.entries(tables: [table], logs: [], where: { _ in true })
        #expect(found[Fixture.key("g")] == Array("value".utf8))
    }

    @Test func aCopyCanRepeatItsOwnOutput() {
        // "ab" and then a copy of six bytes from two back.
        let bytes: [UInt8] = [8, 1 << 2, 97, 98, (6 - 4) << 2 | 1, 2]
        #expect(LevelDB.snappy(ArraySlice(bytes)) == Array("abababab".utf8))
    }

    @Test func aFileCutAnywhereGivesWhatItHas() {
        let table = [UInt8](Fixture.table([(Fixture.key("g"), 1, Fixture.group("g", "Name", order: 0))], compressed: true))
        let log = [UInt8](Fixture.log(from: 1, [(Fixture.key("g"), Fixture.group("g", "Name", order: 0))]))
        for cut in 0..<max(table.count, log.count) {
            _ = ChromiumTabGroups.read(tables: [Data(table.prefix(cut))], logs: [Data(log.prefix(cut))])
            var bad = table
            if cut < bad.count {
                bad[cut] ^= 0xFF
                _ = ChromiumTabGroups.read(tables: [Data(bad)], logs: [])
            }
        }
    }
}

@Suite struct ImportReportTests {
    private func report() -> ImportReport {
        var report = ImportReport(source: "Aside")
        report.folders = ["Email", "Bookmarks"]
        report.home = "Personal"
        report.tabs = 12
        report.passwords = 1
        report.sites = 400
        report.extensions = ["Proton Pass"]
        report.extensionsOff = 1
        report.pages = 29_981
        report.leftBehind = "Anything in Aside Vault stays there"
        report.staysBehind = "Passkeys stay behind"
        return report
    }

    @Test func itSaysWhatCameWhereAndWhatDidnt() {
        let report = report()
        #expect(report.headline == "Here's what came over from Aside")
        let added = report.lines.filter { $0.kind == .added }
        #expect(added.first?.title == "2 folders with 12 tabs in Personal")
        #expect(added.first?.detail == "Email and Bookmarks")
        #expect(added.map(\.title).contains("1 password"))
        #expect(added.map(\.title).contains("29,981 pages of history"))
        #expect(report.lines.filter { $0.kind == .needsYou }.map(\.title) == ["Anything in Aside Vault stays there"])
        #expect(report.lines.filter { $0.kind == .skipped }.map(\.title)
            == ["No new cards or addresses", "1 extension stayed off, as in Aside", "Passkeys stay behind"])
    }

    @Test func arcsSpacesAreCalledSpaces() {
        var report = ImportReport(source: "Arc")
        report.spaces = ["Home", "School"]
        report.tabs = 13
        #expect(report.lines.first?.title == "2 Spaces with 13 tabs")
    }

    @Test func aSecondRunSaysThereWasNothingNew() {
        let report = ImportReport(source: "Aside")
        #expect(report.headline == "Everything from Aside is already here")
        #expect(report.message == "Everything from Aside is already here")
        #expect(!report.lines.contains { $0.kind == .added })
    }

    @Test func aRefusalLeadsWithWhatHappened() {
        var report = ImportReport(source: "Aside")
        report.pages = 2
        report.problem = "Passwords stayed behind"
        report.extensionsFailed = 2
        #expect(report.failed)
        #expect(report.headline == "Some of Aside stayed behind")
        #expect(report.lines.filter { $0.kind == .needsYou }.map(\.title) == ["Passwords stayed behind", "2 extensions couldn't be added"])
        #expect(!report.lines.contains { $0.title == "No new passwords" })
    }
}
