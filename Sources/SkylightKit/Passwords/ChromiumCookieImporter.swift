import Foundation
import SkylightCore
import SQLite3

/// Reads cookies from a Chromium profile's `Cookies` database on macOS, so sites stay signed in.
/// They use the same key and encryption as its passwords.
public enum ChromiumCookieImporter {
    /// Reads and decrypts every live cookie. Rows that fail to decrypt are skipped.
    public static func read(cookies file: URL, safeStorageKey: String, now: Date = .now) throws -> [WebCookie] {
        try ChromiumPasswordImporter.withCopy(of: file) { db in
            let version = Int(try ChromiumPasswordImporter.scalar(db, "SELECT value FROM meta WHERE key = 'version'") ?? "0") ?? 0
            let key = ChromiumPasswordImporter.derivedKey(safeStorageKey)
            // A partitioned cookie belongs to one embedding site, which CEF has no way to set.
            let partitioned = try ChromiumPasswordImporter.scalar(db, "SELECT 1 FROM pragma_table_info('cookies') WHERE name = 'top_frame_site_key'") != nil
            let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies"
                + (partitioned ? " WHERE top_frame_site_key = ''" : "")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ChromiumImportError.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var found: [WebCookie] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let domain = ChromiumPasswordImporter.text(statement, 0), !domain.isEmpty,
                      let name = ChromiumPasswordImporter.text(statement, 1) else { continue }
                let expires = sqlite3_column_int64(statement, 5)
                let date = expires > 0 ? ChromiumPasswordImporter.chromiumDate(expires) : nil
                if let date, date <= now { continue }
                let blob = ChromiumPasswordImporter.data(statement, 3)
                let value = blob.isEmpty ? ChromiumPasswordImporter.text(statement, 2)
                    : ChromiumPasswordImporter.decrypt(blob, key: key, stripsHostHash: version >= 24)
                guard let value else { continue }
                found.append(WebCookie(name: name, value: value, domain: domain,
                                       path: ChromiumPasswordImporter.text(statement, 4) ?? "/",
                                       isSecure: sqlite3_column_int(statement, 6) != 0,
                                       isHTTPOnly: sqlite3_column_int(statement, 7) != 0,
                                       expires: date,
                                       // Chromium counts from -1: unspecified, none, lax, strict.
                                       sameSite: .init(rawValue: Int(sqlite3_column_int(statement, 8)) + 1) ?? .unspecified))
            }
            return found
        }
    }
}
