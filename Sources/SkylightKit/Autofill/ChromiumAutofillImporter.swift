import Foundation
import SQLite3

/// Reads saved addresses and cards from a Chromium profile's `Web Data`. Cards kept in Google Pay
/// are only their last four digits there, so they can't come over.
public enum ChromiumAutofillImporter {
    /// Chromium's numbers for an address's parts (`FieldType` in `field_types.h`).
    private enum Part {
        static let first: Int32 = 3, last: Int32 = 5, name: Int32 = 7, email: Int32 = 9, phone: Int32 = 14
        static let line1: Int32 = 30, line2: Int32 = 31, city: Int32 = 33, state: Int32 = 34, zip: Int32 = 35
        static let country: Int32 = 36, company: Int32 = 60, street: Int32 = 77
    }

    /// The current table, and the two it replaced.
    private static let addressTables = ["address_type_tokens", "local_addresses_type_tokens", "contact_info_type_tokens"]

    public static func read(webData: URL, safeStorageKey: String) throws -> AutofillData {
        try ChromiumPasswordImporter.withCopy(of: webData) { db in
            var found = AutofillData()
            _ = found.merge(AutofillData(addresses: addresses(in: db), cards: cards(in: db, key: ChromiumPasswordImporter.derivedKey(safeStorageKey))))
            return found
        }
    }

    private static func exists(_ table: String, in db: OpaquePointer?) -> Bool {
        (try? ChromiumPasswordImporter.scalar(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(table)'")) != nil
    }

    private static func addresses(in db: OpaquePointer?) -> [AutofillAddress] {
        var parts: [String: [Int32: String]] = [:]
        var order: [String] = []
        for table in addressTables where exists(table, in: db) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT guid, type, value FROM \(table)", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let guid = ChromiumPasswordImporter.text(statement, 0),
                      let value = ChromiumPasswordImporter.text(statement, 2), !value.isEmpty else { continue }
                if parts[guid] == nil { order.append(guid) }
                parts[guid, default: [:]][sqlite3_column_int(statement, 1)] = value
            }
        }
        return order.compactMap { guid in
            let part = parts[guid] ?? [:]
            var address = AutofillAddress(id: guid)
            address.name = part[Part.name] ?? [part[Part.first], part[Part.last]].compactMap(\.self).joined(separator: " ")
            address.company = part[Part.company] ?? ""
            let street = part[Part.street]?.split(whereSeparator: \.isNewline).map(String.init) ?? []
            address.line1 = part[Part.line1] ?? street.first ?? ""
            address.line2 = part[Part.line2] ?? street.dropFirst().joined(separator: ", ")
            address.city = part[Part.city] ?? ""
            address.state = part[Part.state] ?? ""
            address.zip = part[Part.zip] ?? ""
            address.country = part[Part.country] ?? ""
            address.phone = part[Part.phone] ?? ""
            address.email = part[Part.email] ?? ""
            return address.isEmpty ? nil : address
        }
    }

    private static func cards(in db: OpaquePointer?, key: [UInt8]) -> [AutofillCard] {
        guard exists("credit_cards", in: db) else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT guid, name_on_card, expiration_month, expiration_year, card_number_encrypted FROM credit_cards"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var found: [AutofillCard] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let blob = ChromiumPasswordImporter.data(statement, 4)
            guard let plain = ChromiumPasswordImporter.decrypt(blob, key: key, stripsHostHash: false) else { continue }
            let number = plain.filter(\.isNumber)
            guard number.count >= 12, number.count <= 19 else { continue }
            found.append(AutofillCard(id: ChromiumPasswordImporter.text(statement, 0) ?? UUID().uuidString,
                                      name: ChromiumPasswordImporter.text(statement, 1) ?? "", number: number,
                                      month: Int(sqlite3_column_int(statement, 2)), year: Int(sqlite3_column_int(statement, 3))))
        }
        return found
    }
}
