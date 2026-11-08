import Foundation

/// What an import did, in the words the screens show it in.
public struct ImportReport: Equatable, Identifiable, Sendable {
    public struct Line: Equatable, Identifiable, Sendable {
        public enum Kind: Sendable { case added, needsYou, skipped }

        public var kind: Kind
        public var title: String
        public var detail: String?
        public var id: String { title }

        public init(kind: Kind, title: String, detail: String? = nil) {
            self.kind = kind
            self.title = title
            self.detail = detail
        }
    }

    public var source: String
    public var profiles = 0
    /// The names of the Spaces it made.
    public var spaces: [String] = []
    /// The names of the folders it made, and the Space they went in.
    public var folders: [String] = []
    public var home = ""
    public var tabs = 0
    public var passwords = 0
    public var sites = 0
    /// The names of the extensions it added.
    public var extensions: [String] = []
    public var extensionsFailed = 0
    public var extensionsOff = 0
    public var addresses = 0
    public var cards = 0
    public var pages = 0
    /// Something went wrong, and this says what.
    public var problem: String?
    /// What this browser keeps out of reach.
    public var leftBehind: String?
    /// What no browser can give up.
    public var staysBehind: String?

    public init(source: String) { self.source = source }

    public var id: String { source + message }
    public var failed: Bool { problem != nil }

    private var nothingNew: Bool { summary.isEmpty && spaces.isEmpty && folders.isEmpty }

    public var headline: String {
        if failed { return "Some of \(source) stayed behind" }
        return nothingNew ? "Everything from \(source) is already here" : "Here's what came over from \(source)"
    }

    /// What came over, then what needs you, then what was left and why.
    public var lines: [Line] {
        var added: [Line] = []
        func add(_ title: String, _ detail: String? = nil) { added.append(Line(kind: .added, title: title, detail: detail)) }
        if profiles > 0 { add(Self.count(profiles, "profile")) }
        let tabCount = Self.count(tabs, "tab")
        if !spaces.isEmpty {
            let made = Self.count(spaces.count, "Space")
            add(tabs > 0 ? "\(made) with \(tabCount)" : made, Self.list(spaces))
        } else if !folders.isEmpty {
            let made = Self.count(folders.count, "folder")
            add("\(made) with \(tabCount) in \(home)", Self.list(folders))
        } else if tabs > 0 {
            add(Self.count(tabs, "tab"), "In your sidebar")
        }
        if passwords > 0 { add(Self.count(passwords, "password"), "Click the key in the address field to fill one") }
        if sites > 0 { add("Sign-ins for \(Self.count(sites, "site"))", "Some sites may still ask you to sign in again") }
        if !extensions.isEmpty { add(Self.count(extensions.count, "extension"), Self.list(extensions)) }
        let wallet = [Self.count(cards, "card"), Self.count(addresses, "address", "addresses")]
            .enumerated().filter { [cards, addresses][$0.offset] > 0 }.map(\.element)
        if !wallet.isEmpty { add(Self.list(wallet), "Offered when you fill in a form") }
        if pages > 0 { add(Self.count(pages, "page") + " of history", "Suggested as you type") }

        var attention: [Line] = []
        if let problem { attention.append(Line(kind: .needsYou, title: problem)) }
        if extensionsFailed > 0 {
            let those = Self.count(extensionsFailed, "extension")
            attention.append(Line(kind: .needsYou, title: "\(those) couldn't be added", detail: "Add from Settings → Extensions"))
        }
        if let leftBehind { attention.append(Line(kind: .needsYou, title: leftBehind)) }

        var skipped: [String] = []
        if !failed {
            if passwords == 0 { skipped.append("No new passwords") }
            if cards == 0, addresses == 0 { skipped.append("No new cards or addresses") }
        }
        if extensionsOff > 0 {
            let those = Self.count(extensionsOff, "extension")
            skipped.append("\(those) stayed off, as in \(source)")
        }
        if let staysBehind { skipped.append(staysBehind) }
        return added + attention + skipped.map { Line(kind: .skipped, title: $0) }
    }

    /// All of it in a sentence, for a toast or a line in Settings.
    public var message: String {
        let found = [summary.isEmpty ? nil : "Imported \(Self.list(summary)) from \(source)", problem].compactMap(\.self).joined(separator: ". ")
        return [found.isEmpty ? "Everything from \(source) is already here" : found, leftBehind].compactMap(\.self).joined(separator: ". ")
    }

    private var summary: [String] {
        var parts: [String] = []
        if profiles > 0 { parts.append(Self.count(profiles, "profile")) }
        if tabs > 0 { parts.append(Self.count(tabs, "tab")) }
        if passwords > 0 { parts.append(Self.count(passwords, "password")) }
        if sites > 0 { parts.append("sign-ins for \(Self.count(sites, "site"))") }
        if !extensions.isEmpty { parts.append(Self.count(extensions.count, "extension")) }
        if addresses > 0 { parts.append(Self.count(addresses, "address", "addresses")) }
        if cards > 0 { parts.append(Self.count(cards, "card")) }
        if pages > 0 { parts.append(Self.count(pages, "page") + " of history") }
        return parts
    }

    private static func count(_ number: Int, _ one: String, _ many: String? = nil) -> String {
        "\(number.formatted()) \(number == 1 ? one : many ?? one + "s")"
    }

    private static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }
}
