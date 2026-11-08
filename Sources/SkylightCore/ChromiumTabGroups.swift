import Foundation

/// The tab groups a Chromium browser keeps, from `Sync Data/LevelDB`. Aside's sidebar sections
/// are these, and Chrome's saved groups too. That database also holds what the browser syncs,
/// so only keys naming a saved group are ever kept.
public enum ChromiumTabGroups {
    /// Each group as a folder, in the order the browser shows them. `tables` are the database's
    /// `.ldb` files and `logs` its `.log` files.
    public static func read(tables: [Data], logs: [Data]) -> [BrowserImport.ImportedFolder] {
        let entries = LevelDB.entries(tables: tables, logs: logs, where: isGroup)
        var groups: [(id: [UInt8], name: String, color: FolderColor?, order: [Int64])] = []
        var tabs: [[UInt8]: [(link: BrowserImport.Link, position: Int64)]] = [:]
        for value in entries.values {
            guard let saved = Specifics(value) else { continue }
            if let group = saved.group {
                let name = group.bytes(2).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
                let color = group.number(3).flatMap(FolderColor.init(chromium:))
                groups.append((saved.id, name, color, [group.number(4) ?? .max, group.number(1) ?? .max]))
            } else if let tab = saved.tab, let group = tab.bytes(1).map(Array.init), let link = link(tab) {
                tabs[group, default: []].append((link, tab.number(2) ?? .max))
            }
        }

        var folders: [BrowserImport.ImportedFolder] = []
        for group in groups.sorted(by: { $0.order.lexicographicallyPrecedes($1.order) }) {
            // A tab whose group has gone is one the browser no longer shows.
            let links = (tabs[group.id] ?? []).sorted { $0.position < $1.position }.prefix(80).map(\.link)
            guard !links.isEmpty else { continue }
            folders.append(.init(name: group.name.isEmpty ? "Group \(folders.count + 1)" : group.name, links: links, color: group.color))
        }
        return folders
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
