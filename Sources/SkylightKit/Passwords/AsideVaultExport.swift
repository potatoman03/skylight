import Foundation

/// A JSON export from Aside Vault. Aside turns off Chromium's own password, card and address saving
/// when the Vault is on, and the Vault is encrypted, so an export is the only way these leave it.
/// Its CSV has logins alone; this has cards and addresses too. Passkeys stay: Skylight can't hold them.
public enum AsideVaultExport {
    public enum ReadError: Error, LocalizedError, Equatable {
        case unreadable

        public var errorDescription: String? {
            "This isn't a JSON export from Aside Vault. Other password managers can export a CSV instead."
        }
    }

    public struct Contents: Sendable {
        public var credentials: [Credential] = []
        public var autofill = AutofillData()
    }

    private enum Category {
        static let login = "001", card = "002", identity = "004"
    }

    public static func read(_ data: Data, source: String = "Aside Vault") throws -> Contents {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { throw ReadError.unreadable }
        var contents = Contents()
        for item in items where (item["state"] as? String) != "trashed" {
            switch item["category"] as? String {
            case Category.login: contents.credentials += logins(in: item, source: source)
            case Category.card: card(in: item).map { contents.autofill.cards.append($0) }
            case Category.identity: address(in: item).map { contents.autofill.addresses.append($0) }
            default: break
            }
        }
        return contents
    }

    /// One login for each site it's used on.
    private static func logins(in item: [String: Any], source: String) -> [Credential] {
        let fields = item["loginFields"] as? [[String: Any]] ?? []
        func field(_ designation: String) -> String? {
            fields.first { $0["designation"] as? String == designation }?["value"] as? String
        }
        guard let password = field("password"), !password.isEmpty else { return [] }
        var seen = Set<String>()
        return (item["urls"] as? [[String: Any]] ?? [])
            .compactMap { ($0["url"] as? String).flatMap(CredentialOrigin.normalize) }
            .filter { seen.insert($0).inserted }
            .map { Credential(origin: $0, username: field("username") ?? "", password: password, source: source) }
    }

    private static func card(in item: [String: Any]) -> AutofillCard? {
        let number = (value("ccnum", in: item)?["creditCardNumber"] as? String ?? "").filter(\.isNumber)
        guard number.count >= 12, number.count <= 19 else { return nil }
        // Year and month together, as 203307.
        let expiry = value("expiry", in: item)?["monthYear"] as? Int ?? 0
        return AutofillCard(name: text("cardholder", in: item), number: number, month: expiry % 100, year: expiry / 100)
    }

    private static func address(in item: [String: Any]) -> AutofillAddress? {
        var address = AutofillAddress()
        address.name = [text("firstname", in: item), text("initial", in: item), text("lastname", in: item)]
            .filter { !$0.isEmpty }.joined(separator: " ")
        address.company = text("company", in: item)
        if let home = value("address", in: item)?["address"] as? [String: Any] {
            address.line1 = home["street"] as? String ?? ""
            address.city = home["city"] as? String ?? ""
            address.state = home["state"] as? String ?? ""
            address.zip = home["zip"] as? String ?? ""
            address.country = home["country"] as? String ?? ""
        }
        address.phone = value("defphone", in: item)?["phone"] as? String ?? ""
        address.email = (value("email", in: item)?["email"] as? [String: Any])?["email_address"] as? String ?? ""
        return address.isEmpty ? nil : address
    }

    private static func text(_ id: String, in item: [String: Any]) -> String {
        value(id, in: item)?["string"] as? String ?? ""
    }

    private static func value(_ id: String, in item: [String: Any]) -> [String: Any]? {
        for case let section as [String: Any] in item["sections"] as? [Any] ?? [] {
            for case let field as [String: Any] in section["fields"] as? [Any] ?? [] where field["id"] as? String == id {
                return field["value"] as? [String: Any]
            }
        }
        return nil
    }
}
