import Foundation

/// Password exports as CSV: Chrome, Edge, Arc, Safari, 1Password, Bitwarden and friends.
public enum PasswordCSV {
    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case missingColumns

        public var errorDescription: String? {
            switch self {
            case .empty: "The file is empty."
            case .missingColumns: "The file needs a header row with url, username and password columns."
            }
        }
    }

    static let urlColumns = ["url", "login_uri", "website", "login url", "uri", "web site", "origin"]
    static let usernameColumns = ["username", "login_username", "login name", "user", "email", "login"]
    static let passwordColumns = ["password", "login_password"]

    /// Reads credentials from a CSV with a header row. Rows without a web address or password are skipped.
    public static func parse(_ text: String, source: String) throws -> [Credential] {
        let rows = records(text)
        guard let header = rows.first else { throw ParseError.empty }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ candidates: [String]) -> Int? {
            candidates.lazy.compactMap { names.firstIndex(of: $0) }.first
        }
        guard let url = column(urlColumns), let password = column(passwordColumns) else { throw ParseError.missingColumns }
        let username = column(usernameColumns)

        var seen = Set<String>()
        return rows.dropFirst().compactMap { row -> Credential? in
            func field(_ index: Int?) -> String { index.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            // Bitwarden puts several addresses in one cell; the first is enough.
            let address = field(url).split(whereSeparator: { $0 == "," || $0.isNewline }).first.map(String.init) ?? ""
            guard let origin = CredentialOrigin.normalize(address), !field(password).isEmpty else { return nil }
            let credential = Credential(origin: origin, username: field(username), password: field(password), source: source)
            return seen.insert(credential.id).inserted ? credential : nil
        }
    }

    /// Chrome's export format: `name,url,username,password,note`.
    public static func export(_ credentials: [Credential]) -> String {
        var lines = ["name,url,username,password,note"]
        for c in credentials {
            lines.append([c.displayHost, c.origin + "/", c.username, c.password, ""].map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180 records: quoted fields may hold commas, quotes and line breaks.
    static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.hasPrefix("\u{FEFF}") ? Substring(text.dropFirst()) : Substring(text)
        // Swift treats "\r\n" as one Character, which keeps CRLF handling simple.
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c.isNewline {
                row.append(field); field = ""
                if row != [""] { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
        }
        row.append(field)
        if row != [""] { rows.append(row) }
        return rows
    }
}
