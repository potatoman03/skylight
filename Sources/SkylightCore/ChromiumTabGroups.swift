import Foundation

/// The tab groups a Chromium browser keeps, from `Sync Data/LevelDB`. Aside's sidebar sections
/// are these, and Chrome's saved groups too. That database also holds what the browser syncs,
/// so only keys naming a saved group are ever kept.
public enum ChromiumTabGroups {
    /// How many become Spaces. Anything past them lands in a Space named after the browser.
    static let spaceLimit = 8

    /// Each group as a Space, in the order the browser shows them. `tables` are the database's
    /// `.ldb` files and `logs` its `.log` files.
    public static func read(tables: [Data], logs: [Data], browser: String) -> [BrowserImport.ImportedSpace] {
        let entries = LevelDB.entries(tables: tables, logs: logs, where: isGroup)
        var groups: [(id: [UInt8], space: BrowserImport.ImportedSpace, order: [Int64])] = []
        var tabs: [[UInt8]: [(link: BrowserImport.Link, position: Int64)]] = [:]
        for value in entries.values {
            guard let saved = Specifics(value) else { continue }
            if let group = saved.group {
                let name = group.bytes(2).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
                groups.append((saved.id, .init(name: name, icon: "folder", hue: hue(of: group.number(3)), pinned: []),
                               [group.number(4) ?? .max, group.number(1) ?? .max]))
            } else if let tab = saved.tab, let group = tab.bytes(1).map(Array.init), let link = link(tab) {
                tabs[group, default: []].append((link, tab.number(2) ?? .max))
            }
        }

        var spaces: [BrowserImport.ImportedSpace] = []
        for var group in groups.sorted(by: { $0.order.lexicographicallyPrecedes($1.order) }) {
            // A tab whose group has gone is one the browser no longer shows.
            group.space.pinned = (tabs[group.id] ?? []).sorted { $0.position < $1.position }.prefix(80).map(\.link)
            guard !group.space.pinned.isEmpty else { continue }
            if group.space.name.isEmpty { group.space.name = "Group \(spaces.count + 1)" }
            spaces.append(group.space)
        }
        let rest = Array(spaces.dropFirst(spaceLimit).flatMap(\.pinned).prefix(80))
        return spaces.prefix(spaceLimit) + (rest.isEmpty ? [] : [.init(name: browser, icon: "bookmark", pinned: rest)])
    }

    /// Chromium keeps one store for this device and one for the signed-in account.
    private static func isGroup(_ key: [UInt8]) -> Bool {
        let local = Array("saved_tab_group-dt-".utf8)
        return key.starts(with: local) || key.starts(with: Array("A-".utf8) + local)
    }

    private static func link(_ tab: Fields) -> BrowserImport.Link? {
        guard let raw = tab.bytes(3).flatMap({ String(bytes: $0, encoding: .utf8) }), let url = URL(string: raw),
              ["http", "https"].contains(url.scheme ?? "") else { return nil }
        let title = tab.bytes(4).flatMap { String(bytes: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        return BrowserImport.Link(url: url, title: title ?? url.host() ?? raw)
    }

    /// `SavedTabGroupColor`. Grey has no hue worth keeping.
    private static func hue(of color: Int64?) -> Double? {
        switch color {
        case 2: 0.6
        case 3: 0
        case 4: 0.13
        case 5: 0.38
        case 6: 0.92
        case 7: 0.77
        case 8: 0.5
        case 9: 0.07
        default: nil
        }
    }

    /// `SavedTabGroupSpecifics`, wrapped in `SavedTabGroupData` by newer browsers.
    private struct Specifics {
        let id: [UInt8]
        let group: Fields?
        let tab: Fields?

        init?(_ value: [UInt8]) {
            guard let outer = Fields(value) else { return nil }
            let fields = outer.bytes(2).flatMap { Fields($0) } ?? outer
            guard let id = fields.bytes(1) else { return nil }
            self.id = Array(id)
            group = fields.bytes(4).flatMap { Fields($0) }
            tab = fields.bytes(5).flatMap { Fields($0) }
        }
    }

    /// One protobuf message's numbers and byte strings, by field.
    private struct Fields {
        private var numbers: [UInt64: UInt64] = [:]
        private var strings: [UInt64: ArraySlice<UInt8>] = [:]

        init?(_ bytes: some Sequence<UInt8>) {
            var cursor = LevelDB.Cursor(Array(bytes))
            while !cursor.isAtEnd {
                guard let tag = cursor.varint() else { return nil }
                switch tag & 7 {
                case 0:
                    guard let value = cursor.varint() else { return nil }
                    numbers[tag >> 3] = value
                case 1: guard cursor.take(8) != nil else { return nil }
                case 2:
                    guard let size = cursor.length(), let value = cursor.take(size) else { return nil }
                    strings[tag >> 3] = value
                case 5: guard cursor.take(4) != nil else { return nil }
                default: return nil
                }
            }
        }

        func number(_ field: UInt64) -> Int64? { numbers[field].map { Int64(truncatingIfNeeded: $0) } }
        func bytes(_ field: UInt64) -> ArraySlice<UInt8>? { strings[field] }
    }
}
