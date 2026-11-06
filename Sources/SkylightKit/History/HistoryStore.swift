import Foundation
import SkylightCore
import SQLite3

/// A page you've been to.
public struct HistoryEntry: Identifiable, Equatable, Sendable {
    public var url: URL
    public var title: String
    public var count: Int
    public var last: Date

    public var id: String { url.absoluteString }

    public init(url: URL, title: String, count: Int = 1, last: Date) {
        self.url = url
        self.title = title
        self.count = count
        self.last = last
    }

    public var displayTitle: String { title.isEmpty ? url.host() ?? url.absoluteString : title }
}

/// Where you've been, in each profile, in one small database. It's indexed for the address field,
/// which asks on every keystroke, and a write doesn't wait for the disk.
@MainActor
public final class HistoryStore {
    nonisolated(unsafe) private var db: OpaquePointer?

    /// With no file, it's kept in memory.
    public init(file: URL?) {
        if let file { try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        guard sqlite3_open(file?.path ?? ":memory:", &db) == SQLITE_OK else { return }
        sqlite3_exec(db, """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS visits(profile TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
                                          count INTEGER NOT NULL, last REAL NOT NULL, PRIMARY KEY(profile, url)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS visits_by_time ON visits(profile, last DESC);
        """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String, _ bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> Void = { _ in }) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, Self.transient)
    }

    public func record(_ url: URL, title: String, in profile: ProfileID, at time: Date = .now) {
        guard ["http", "https"].contains(url.scheme ?? "") else { return }
        run("""
        INSERT INTO visits VALUES(?, ?, ?, 1, ?)
        ON CONFLICT(profile, url) DO UPDATE SET count = count + 1, last = excluded.last,
          title = CASE excluded.title WHEN '' THEN title ELSE excluded.title END
        """, { [self] s in
            bind(s, 1, "\(profile)")
            bind(s, 2, url.absoluteString)
            bind(s, 3, title)
            sqlite3_bind_double(s, 4, time.timeIntervalSince1970)
        })
    }

    public func setTitle(_ title: String, of url: URL, in profile: ProfileID) {
        run("UPDATE visits SET title = ? WHERE profile = ? AND url = ?", { [self] s in
            bind(s, 1, title)
            bind(s, 2, "\(profile)")
            bind(s, 3, url.absoluteString)
        })
    }

    /// Adds entries from another browser, keeping the larger count and the later visit of a page
    /// that's in both. Returns how many it was given that were new.
    @discardableResult
    public func add(_ entries: [HistoryEntry], to profile: ProfileID) -> Int {
        let before = count(in: profile)
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for entry in entries where ["http", "https"].contains(entry.url.scheme ?? "") {
            run("""
            INSERT INTO visits VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(profile, url) DO UPDATE SET count = max(count, excluded.count), last = max(last, excluded.last)
            """, { [self] s in
                bind(s, 1, "\(profile)")
                bind(s, 2, entry.url.absoluteString)
                bind(s, 3, entry.title)
                sqlite3_bind_int64(s, 4, Int64(entry.count))
                sqlite3_bind_double(s, 5, entry.last.timeIntervalSince1970)
            })
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return count(in: profile) - before
    }

    public func count(in profile: ProfileID) -> Int {
        var total = 0
        run("SELECT count(*) FROM visits WHERE profile = ?", { [self] in bind($0, 1, "\(profile)") }, row: { total = Int(sqlite3_column_int64($0, 0)) })
        return total
    }

    /// Pages for the address field: sites that start with what you typed, then the ones you go to most.
    public func suggestions(for query: String, in profile: ProfileID, limit: Int = 4) -> [HistoryEntry] {
        let text = Self.escaped(query.lowercased())
        guard !text.isEmpty else { return [] }
        return rows("""
        SELECT url, title, count, last FROM visits WHERE profile = ?1 AND (url LIKE ?2 ESCAPE '\\' OR title LIKE ?2 ESCAPE '\\')
        ORDER BY (url LIKE ?3 ESCAPE '\\' OR url LIKE ?4 ESCAPE '\\' OR url LIKE ?5 ESCAPE '\\' OR url LIKE ?6 ESCAPE '\\') DESC,
                 count DESC, last DESC LIMIT ?7
        """) { [self] s in
            bind(s, 1, "\(profile)")
            bind(s, 2, "%\(text)%")
            for (index, scheme) in ["https://", "https://www.", "http://", "http://www."].enumerated() {
                bind(s, Int32(index + 3), "\(scheme)\(text)%")
            }
            sqlite3_bind_int(s, 7, Int32(limit))
        }
    }

    /// The newest pages, or the newest that match `search`.
    public func recent(in profile: ProfileID, matching search: String = "", limit: Int = 300) -> [HistoryEntry] {
        rows("""
        SELECT url, title, count, last FROM visits
        WHERE profile = ?1 AND (?2 = '%%' OR url LIKE ?2 ESCAPE '\\' OR title LIKE ?2 ESCAPE '\\')
        ORDER BY last DESC LIMIT ?3
        """) { [self] s in
            bind(s, 1, "\(profile)")
            bind(s, 2, "%\(Self.escaped(search))%")
            sqlite3_bind_int(s, 3, Int32(limit))
        }
    }

    public func remove(_ url: URL, from profile: ProfileID) {
        run("DELETE FROM visits WHERE profile = ? AND url = ?", { [self] s in
            bind(s, 1, "\(profile)")
            bind(s, 2, url.absoluteString)
        })
    }

    public func clear(_ profile: ProfileID) {
        run("DELETE FROM visits WHERE profile = ?", { [self] in bind($0, 1, "\(profile)") })
    }

    private func rows(_ sql: String, _ bind: (OpaquePointer?) -> Void) -> [HistoryEntry] {
        var found: [HistoryEntry] = []
        run(sql, bind, row: { s in
            guard let url = sqlite3_column_text(s, 0).flatMap({ URL(string: String(cString: $0)) }) else { return }
            let title = sqlite3_column_text(s, 1).map { String(cString: $0) } ?? ""
            found.append(HistoryEntry(url: url, title: title, count: Int(sqlite3_column_int64(s, 2)),
                                      last: Date(timeIntervalSince1970: sqlite3_column_double(s, 3))))
        })
        return found
    }

    /// `%` and `_` in what you typed are just characters.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Reads a Chromium profile's `History`.
public enum ChromiumHistoryImporter {
    /// The most recent pages, up to `limit`. Pages Chromium hides, like frames, are left out.
    public static func read(history: URL, limit: Int = 20000) throws -> [HistoryEntry] {
        try ChromiumPasswordImporter.withCopy(of: history) { db in
            var statement: OpaquePointer?
            let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT \(limit)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ChromiumImportError.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var found: [HistoryEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let url = ChromiumPasswordImporter.text(statement, 0).flatMap(URL.init(string:)) else { continue }
                found.append(HistoryEntry(url: url, title: ChromiumPasswordImporter.text(statement, 1) ?? "",
                                          count: Int(sqlite3_column_int64(statement, 2)),
                                          last: ChromiumPasswordImporter.chromiumDate(sqlite3_column_int64(statement, 3))))
            }
            return found
        }
    }
}
