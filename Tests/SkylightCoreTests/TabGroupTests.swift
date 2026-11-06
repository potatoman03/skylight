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

    static func group(_ id: String, _ title: String, order: Int64, color: Int64 = 2, wrapped: Bool = true) -> [UInt8] {
        let group = string(2, title) + number(3, color) + number(4, order)
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
    @Test func groupsComeOutInTheOrderTheBrowserShows() {
        let log = Fixture.log(from: 10, [
            (Fixture.key("b"), Fixture.group("b", "Second", order: 1)),
            (Fixture.key("a"), Fixture.group("a", "First", order: 0, color: 1)),
            (Fixture.key("t1"), Fixture.tab("t1", in: "a", "https://one.example/", "One", at: 1)),
            (Fixture.key("t2"), Fixture.tab("t2", in: "a", "https://two.example/", "Two", at: 0)),
            (Fixture.key("t3"), Fixture.tab("t3", in: "b", "https://three.example/page")),
            (Fixture.key("t4"), Fixture.tab("t4", in: "b", "aside://settings/", "Internal")),
            (Array("passwords-dt-x".utf8), Array("not a group".utf8)),
        ])
        let spaces = ChromiumTabGroups.read(tables: [], logs: [log], browser: "Aside")
        #expect(spaces.map(\.name) == ["First", "Second"])
        #expect(spaces[0].pinned.map(\.title) == ["Two", "One"])
        #expect(spaces[1].pinned.map(\.title) == ["three.example"])
        #expect(spaces[0].hue == nil)
        #expect(spaces[1].hue == 0.6)
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
        let spaces = ChromiumTabGroups.read(tables: [table], logs: [log], browser: "Aside")
        #expect(spaces.map(\.name) == ["New name"])
        #expect(spaces[0].pinned.map(\.url.host) == ["kept.example"])
    }

    @Test func theOlderFormatAndTheAccountStoreRead() {
        let log = Fixture.log(from: 1, [
            (Array("A-saved_tab_group-dt-g".utf8), Fixture.group("g", "Synced", order: 0, wrapped: false)),
            (Array("A-saved_tab_group-dt-t".utf8), Fixture.tab("t", in: "g", "https://example.com/", wrapped: false)),
        ])
        let spaces = ChromiumTabGroups.read(tables: [], logs: [log], browser: "Chrome")
        #expect(spaces.map(\.name) == ["Synced"])
        #expect(spaces[0].pinned.count == 1)
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

    @Test func pastTheLimitTabsLandInOneSpace() {
        var writes: [(key: [UInt8], value: [UInt8]?)] = []
        for i in 0..<10 {
            writes.append((Fixture.key("g\(i)"), Fixture.group("g\(i)", "Group \(i)", order: Int64(i))))
            writes.append((Fixture.key("t\(i)"), Fixture.tab("t\(i)", in: "g\(i)", "https://site\(i).example/")))
        }
        let spaces = ChromiumTabGroups.read(tables: [], logs: [Fixture.log(from: 1, writes)], browser: "Chrome")
        #expect(spaces.count == ChromiumTabGroups.spaceLimit + 1)
        #expect(spaces.last?.name == "Chrome")
        #expect(spaces.last?.pinned.count == 2)
    }

    @Test func aFileCutAnywhereGivesWhatItHas() {
        let table = [UInt8](Fixture.table([(Fixture.key("g"), 1, Fixture.group("g", "Name", order: 0))], compressed: true))
        let log = [UInt8](Fixture.log(from: 1, [(Fixture.key("g"), Fixture.group("g", "Name", order: 0))]))
        for cut in 0..<max(table.count, log.count) {
            _ = ChromiumTabGroups.read(tables: [Data(table.prefix(cut))], logs: [Data(log.prefix(cut))], browser: "Chrome")
            var bad = table
            if cut < bad.count {
                bad[cut] ^= 0xFF
                _ = ChromiumTabGroups.read(tables: [Data(bad)], logs: [], browser: "Chrome")
            }
        }
    }
}
