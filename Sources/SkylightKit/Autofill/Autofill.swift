import Foundation
import Security
import SkylightCore

/// A saved address.
public struct AutofillAddress: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name = ""
    public var company = ""
    public var line1 = ""
    public var line2 = ""
    public var city = ""
    public var state = ""
    public var zip = ""
    public var country = ""
    public var phone = ""
    public var email = ""

    public init(id: String = UUID().uuidString) { self.id = id }

    /// The address's first line, or whatever else it has, for a menu.
    public var title: String { [name, line1, email, phone].first { !$0.isEmpty } ?? "Address" }
    public var isEmpty: Bool { line1.isEmpty && email.isEmpty && phone.isEmpty && name.isEmpty }

    /// Two copies of one address, in any case and spacing.
    var key: String {
        [name, line1, zip, email, phone].map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.joined(separator: "|")
    }

    /// Values by the form field they belong in. Empty ones are left out.
    public var fields: [String: String] {
        let parts = name.split(separator: " ").map(String.init)
        let all = ["name": name, "given": parts.first ?? "", "family": parts.count > 1 ? parts.last! : "",
                   "organization": company, "line1": line1, "line2": line2, "city": city, "state": state,
                   "zip": zip, "country": country, "tel": phone, "email": email]
        return all.filter { !$0.value.isEmpty }
    }
}

/// A saved card. The security code is never saved, by Chromium or here.
public struct AutofillCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Digits only. Empty in anything listed for the UI; a fill reads it from the store.
    public var number: String
    public var month: Int
    public var year: Int
    public var last4: String

    public init(id: String = UUID().uuidString, name: String, number: String, month: Int, year: Int) {
        self.id = id
        self.name = name
        self.number = number
        self.month = month
        self.year = year
        last4 = String(number.suffix(4))
    }

    public var withoutNumber: AutofillCard {
        var copy = self
        copy.number = ""
        return copy
    }

    public var brand: String {
        switch number.first ?? " " {
        case "4": "Visa"
        case "5", "2": "Mastercard"
        case "3": "American Express"
        case "6": "Discover"
        default: "Card"
        }
    }

    public var title: String { "•••• \(last4)" }

    public var fields: [String: String] {
        let shortYear = String(format: "%02d", year % 100)
        let all = ["cc-name": name, "cc-number": number, "cc-exp": String(format: "%02d/", month) + shortYear,
                   "cc-exp-month": String(format: "%02d", month), "cc-exp-year": String(year)]
        return all.filter { !$0.value.isEmpty }
    }
}

/// One profile's addresses and cards.
public struct AutofillData: Codable, Equatable, Sendable {
    public var addresses: [AutofillAddress] = []
    public var cards: [AutofillCard] = []

    public init(addresses: [AutofillAddress] = [], cards: [AutofillCard] = []) {
        self.addresses = addresses
        self.cards = cards
    }

    public var isEmpty: Bool { addresses.isEmpty && cards.isEmpty }

    /// Adds what isn't here yet, and returns how many of each that was.
    public mutating func merge(_ other: AutofillData) -> (addresses: Int, cards: Int) {
        var keys = Set(addresses.map(\.key))
        var numbers = Set(cards.map(\.number))
        let newAddresses = other.addresses.filter { keys.insert($0.key).inserted }
        let newCards = other.cards.filter { numbers.insert($0.number).inserted }
        addresses += newAddresses
        cards += newCards
        return (newAddresses.count, newCards.count)
    }
}

/// Where addresses and cards live.
@MainActor
public protocol AutofillStore: AnyObject {
    func load(_ profile: ProfileID) throws -> AutofillData
    func save(_ data: AutofillData, in profile: ProfileID) throws
}

/// For tests and demo runs. Nothing here is real.
@MainActor
public final class MemoryAutofillStore: AutofillStore {
    private var profiles: [ProfileID: AutofillData]

    public init(_ profiles: [ProfileID: AutofillData] = [:]) { self.profiles = profiles }

    public static func demo() -> MemoryAutofillStore {
        var address = AutofillAddress(id: "demo")
        address.name = "Sam Example"
        address.line1 = "1 Infinite Loop"
        address.city = "Cupertino"
        address.state = "CA"
        address.zip = "95014"
        address.country = "United States"
        address.phone = "+1 555 010 0000"
        address.email = "sam@example.com"
        // A payment provider's published test number.
        let card = AutofillCard(id: "demo", name: "Sam Example", number: "4242424242424242", month: 4, year: 2031)
        return MemoryAutofillStore([.standard: AutofillData(addresses: [address], cards: [card])])
    }

    public func load(_ profile: ProfileID) throws -> AutofillData { profiles[profile] ?? AutofillData() }
    public func save(_ data: AutofillData, in profile: ProfileID) throws { profiles[profile] = data }
}

/// Addresses and cards in the login Keychain, one encrypted item per profile, so they sit behind
/// the same lock as passwords and never reach Skylight's data folder.
@MainActor
public final class KeychainAutofillStore: AutofillStore {
    private static let service = "Skylight Autofill"

    public init() {}

    private func query(_ profile: ProfileID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "\(profile)"]
    }

    public func load(_ profile: ProfileID) throws -> AutofillData {
        var search = query(profile)
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return AutofillData() }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain(status) }
        return try JSONDecoder().decode(AutofillData.self, from: data)
    }

    public func save(_ data: AutofillData, in profile: ProfileID) throws {
        let encoded = try JSONEncoder().encode(data)
        let status = SecItemUpdate(query(profile) as CFDictionary, [kSecValueData as String: encoded] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
        var item = query(profile)
        item[kSecValueData as String] = encoded
        item[kSecAttrLabel as String] = Self.service
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialStoreError.keychain(added) }
    }
}
