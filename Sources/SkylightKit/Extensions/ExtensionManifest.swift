import CryptoKit
import Foundation
import Security

/// What Skylight reads from a Chrome extension's `manifest.json`: enough to draw its button,
/// open its popup and describe it in Settings. Chromium reads the rest.
public struct ExtensionManifest: Equatable, Sendable {
    public var name: String
    public var version: String
    public var description: String
    public var manifestVersion: Int
    /// Icon files by size in pixels, relative to the extension folder.
    public var icons: [Int: String]
    /// The toolbar button (`action`, or `browser_action` in Manifest V2).
    public var action: Action?
    public var optionsPage: String?
    public var sidePanel: String?
    public var permissions: [String]
    public var hostPermissions: [String]
    /// The sites its content scripts run on, which is access even without a host permission.
    public var contentScriptMatches: [String] = []
    /// The public key that fixes the extension's id (store installs carry one).
    public var key: String?

    public struct Action: Equatable, Sendable {
        public var title: String?
        public var popup: String?
        public var icons: [Int: String]
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case missing
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .missing: "That folder has no manifest.json."
            case let .malformed(reason): "The extension's manifest can't be read: \(reason)"
            }
        }
    }

    /// Reads `manifest.json` from an unpacked extension folder, with `__MSG_…__` names resolved.
    public static func load(from directory: URL) throws -> ExtensionManifest {
        let file = directory.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: file) else { throw Failure.missing }
        return try parse(data, messages: messages(in: directory, data: data))
    }

    public static func parse(_ data: Data, messages: [String: String] = [:]) throws -> ExtensionManifest {
        // Chrome tolerates comments in manifests; strip whole-line ones.
        let cleaned = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let object = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else {
            throw Failure.malformed("not a JSON object")
        }
        func text(_ value: Any?) -> String? {
            guard let raw = value as? String else { return nil }
            return localize(raw, messages)
        }
        guard let name = text(object["name"]), !name.isEmpty else { throw Failure.malformed("no name") }

        let actionObject = (object["action"] ?? object["browser_action"]) as? [String: Any]
        let action = actionObject.map { a in
            Action(title: text(a["default_title"]), popup: (a["default_popup"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                   icons: iconMap(a["default_icon"]))
        }
        let options = (object["options_ui"] as? [String: Any])?["page"] as? String ?? object["options_page"] as? String
        return ExtensionManifest(
            name: name,
            version: object["version"] as? String ?? "",
            description: text(object["description"]) ?? "",
            manifestVersion: object["manifest_version"] as? Int ?? 2,
            icons: iconMap(object["icons"]),
            action: action,
            optionsPage: options,
            sidePanel: (object["side_panel"] as? [String: Any])?["default_path"] as? String,
            permissions: object["permissions"] as? [String] ?? [],
            hostPermissions: object["host_permissions"] as? [String] ?? [],
            contentScriptMatches: (object["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] },
            key: object["key"] as? String)
    }

    /// The best icon at least `size` pixels wide: the action's own, then the extension's.
    public func icon(size: Int) -> String? {
        let all = (action?.icons ?? [:]).merging(icons) { own, _ in own }
        guard !all.isEmpty else { return nil }
        let sorted = all.keys.sorted()
        let pick = sorted.first { $0 >= size } ?? sorted.last!
        return all[pick]
    }

    public var title: String { action?.title ?? name }

    /// Every site it can reach, however the manifest asks for them.
    var hosts: Set<String> {
        Set(hostPermissions + contentScriptMatches + permissions.filter { $0.contains("://") || $0 == "<all_urls>" })
    }

    private var reachesEverySite: Bool {
        hosts.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }
    }

    /// Permissions people should know about before installing, in plain words.
    public var warnings: [String] {
        var out: [String] = []
        if reachesEverySite {
            out.append(Self.everySite)
        } else if !hosts.isEmpty {
            out.append("Read and change your data on \(hosts.count == 1 ? "one site" : "\(hosts.count) sites")")
        }
        return out + permissionWarnings
    }

    private static let everySite = "Read and change everything on every website"

    private var permissionWarnings: [String] {
        let named: [String: String] = [
            "tabs": "See your open tabs and their addresses", "history": "Read your browsing history",
            "bookmarks": "Read and change your bookmarks", "cookies": "Read and change cookies",
            "downloads": "Manage your downloads", "clipboardRead": "Read what you copy",
            "nativeMessaging": "Talk to apps on your Mac", "webRequest": "Watch your network requests",
            "debugger": "Debug and control pages", "management": "Manage your other extensions",
        ]
        return permissions.compactMap { named[$0] }
    }

    /// What an update asks for beyond `old`. Sites are compared themselves: `warnings` only
    /// counts them, and swapping one site for another keeps the count.
    public func addedWarnings(since old: ExtensionManifest) -> [String] {
        let added = permissionWarnings.filter { !old.permissionWarnings.contains($0) }
        let newHosts = hosts.subtracting(old.hosts)
        if old.reachesEverySite || newHosts.isEmpty { return added }
        if reachesEverySite { return [Self.everySite] + added }
        return ["Read and change your data on \(newHosts.count == 1 ? "one more site" : "\(newHosts.count) more sites")"] + added
    }

    // MARK: - Helpers

    static func iconMap(_ value: Any?) -> [Int: String] {
        if let single = value as? String { return [16: single] }
        guard let map = value as? [String: Any] else { return [:] }
        var out: [Int: String] = [:]
        for (size, path) in map {
            if let size = Int(size), let path = path as? String { out[size] = path }
        }
        return out
    }

    static func localize(_ raw: String, _ messages: [String: String]) -> String {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        return messages[key] ?? raw
    }

    /// The `_locales` messages for the user's language, falling back to the default locale.
    static func messages(in directory: URL, data: Data) -> [String: String] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let fallback = object?["default_locale"] as? String
        let preferred = Locale.preferredLanguages.flatMap { lang -> [String] in
            let underscored = lang.replacingOccurrences(of: "-", with: "_")
            return [underscored, String(underscored.prefix(while: { $0 != "_" }))]
        }
        var out: [String: String] = [:]
        for locale in ([fallback].compactMap { $0 } + preferred.reversed()) {
            let file = directory.appending(path: "_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { continue }
            for (key, entry) in map {
                if let message = entry["message"] as? String { out[key.lowercased()] = message }
            }
        }
        return out
    }
}

/// Chrome extension ids: 32 letters a–p, from the SHA-256 of the public key (or, for an
/// unpacked extension without a key, of its folder's path).
public enum ExtensionID {
    public static func from(publicKey: Data) -> String { letters(SHA256.hash(data: publicKey)) }

    /// `key` as written in a manifest (base64 DER).
    public static func from(manifestKey: String) -> String? {
        Data(base64Encoded: manifestKey.filter { !$0.isWhitespace }).map(from(publicKey:))
    }

    public static func from(path: String) -> String { letters(SHA256.hash(data: Data(path.utf8))) }

    public static func isValid(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    private static func letters(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("abcdefghijklmnop")
        return String(digest.prefix(16).flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 0xF)]] })
    }
}

/// The Chrome Web Store: finding an extension's id in what people paste, and where to download it.
public enum WebStore {
    /// Accepts a store link (old or new site) or a bare id.
    public static func extensionID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExtensionID.isValid(trimmed) { return trimmed }
        guard let url = URL(string: trimmed), let host = url.host(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.last { ExtensionID.isValid($0) }
    }

    public static func detailURL(for id: String) -> URL {
        URL(string: "https://chromewebstore.google.com/detail/\(id)")!
    }

    public static let homeURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

    public static func searchURL(for query: String) -> URL {
        let term = query.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return term.isEmpty ? homeURL : URL(string: "https://chromewebstore.google.com/search/\(term)")!
    }

    /// The update service's direct download of the current CRX.
    /// Asks the store for the latest version of each extension, without downloading them.
    public static func updateCheckURL(for versions: [String: String], chromeVersion: String) -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
        ] + versions.sorted { $0.key < $1.key }.map { URLQueryItem(name: "x", value: "id=\($0.key)&v=\($0.value)&uc") }
        return components.url!
    }

    /// The versions the store offers, from an update check's reply:
    /// `<app appid="…"><updatecheck status="ok" version="…"/></app>`. Extensions with no update
    /// are left out.
    public static func availableVersions(in xml: Data) -> [String: String] {
        final class Reader: NSObject, XMLParserDelegate {
            var app: String?
            var found: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String]) {
                if name == "app" { app = attributes["appid"] }
                if name == "updatecheck", let app, attributes["status"] == "ok", let version = attributes["version"] { found[app] = version }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        return reader.found
    }

    /// Whether version `a` is later than `b`, comparing dotted numbers as Chrome does (1.10 > 1.9).
    public static func isVersion(_ a: String, laterThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    public static func downloadURL(for id: String, chromeVersion: String) -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components.url!
    }
}

/// A CRX3 package: a signed header, then a zip of the extension.
public struct CRXPackage: Sendable {
    /// The zip archive.
    public let archive: Data
    /// The developer key that the extension's id derives from, and that signed the package.
    public let publicKey: Data
    /// The extension's id.
    public let id: String

    public enum Failure: Error, LocalizedError, Equatable {
        case notCRX
        case unsupportedVersion(UInt32)
        case badSignature
        case wrongExtension

        public var errorDescription: String? {
            switch self {
            case .notCRX: "The download isn't a Chrome extension."
            case let .unsupportedVersion(v): "That extension uses package format \(v), which Skylight can't open."
            case .badSignature: "The extension's signature doesn't match its contents."
            case .wrongExtension: "The download is a different extension from the one asked for."
            }
        }
    }

    /// Opens a CRX3 package, as Chrome does: it must be signed by the developer key its id comes
    /// from, so nobody but that developer can make a package with that id. Given `expected`, it
    /// must also be that extension.
    public init(_ data: Data, expected: String? = nil) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] else { throw Failure.notCRX }  // "Cr24"
        let version = Self.uint32(bytes, 4)
        guard version == 3 else { throw Failure.unsupportedVersion(version) }
        let headerSize = Int(Self.uint32(bytes, 8))
        guard 12 + headerSize <= bytes.count else { throw Failure.notCRX }
        let header = Array(bytes[12..<(12 + headerSize)])
        let archive = Data(bytes[(12 + headerSize)...])

        // The header is a protobuf `CrxFileHeader`: field 2 holds RSA proofs (a key and a
        // signature), field 10000 the signed data, whose field 1 is the id.
        let fields = Protobuf.fields(header)
        guard let signedData = fields.first(where: { $0.number == 10000 })?.bytes,
              let idBytes = Protobuf.fields(signedData).first(where: { $0.number == 1 })?.bytes, idBytes.count == 16
        else { throw Failure.badSignature }
        let alphabet = Array("abcdefghijklmnop")
        let id = String(idBytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 0xF)]] })
        if let expected, expected != id { throw Failure.wrongExtension }

        // What's signed: a fixed prefix, the signed data's length and the data, then the zip.
        let length = UInt32(signedData.count)
        var message = Data("CRX3 SignedData\u{0}".utf8)
        message.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)])
        message.append(contentsOf: signedData)
        message.append(archive)
        let proofs = fields.filter { $0.number == 2 }.map { Protobuf.fields($0.bytes) }
        guard let proof = proofs.first(where: { proof in
                  proof.first { $0.number == 1 }.map { ExtensionID.from(publicKey: Data($0.bytes)) == id } ?? false
              }),
              let key = proof.first(where: { $0.number == 1 }).map({ Data($0.bytes) }),
              let signature = proof.first(where: { $0.number == 2 }).map({ Data($0.bytes) }),
              Self.verify(signature, of: message, key: key)
        else { throw Failure.badSignature }

        self.archive = archive
        self.publicKey = key
        self.id = id
    }

    static func uint32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// An RSA PKCS #1 v1.5 SHA-256 signature, by a key in the SubjectPublicKeyInfo form Chrome uses.
    static func verify(_ signature: Data, of message: Data, key: Data) -> Bool {
        guard let pkcs1 = pkcs1(fromSPKI: [UInt8](key)),
              let secKey = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                                  kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil)
        else { return false }
        return SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    /// The PKCS #1 key inside a SubjectPublicKeyInfo, which is what Security takes:
    /// SEQUENCE { SEQUENCE algorithm, BIT STRING { 0 unused bits, key } }.
    static func pkcs1(fromSPKI b: [UInt8]) -> Data? {
        guard let outer = der(b, at: 0), outer.tag == 0x30, outer.end == b.count,
              let algorithm = der(b, at: outer.body.lowerBound), algorithm.tag == 0x30,
              let bits = der(b, at: algorithm.end), bits.tag == 0x03, bits.body.count > 1, b[bits.body.lowerBound] == 0
        else { return nil }
        return Data(b[(bits.body.lowerBound + 1)..<bits.body.upperBound])
    }

    /// One DER element at `i`: its tag, where its contents are, and where it ends.
    static func der(_ b: [UInt8], at i: Int) -> (tag: UInt8, body: Range<Int>, end: Int)? {
        guard i + 2 <= b.count else { return nil }
        var length = Int(b[i + 1])
        var start = i + 2
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard (1...4).contains(n), start + n <= b.count else { return nil }
            length = b[start..<(start + n)].reduce(0) { $0 << 8 | Int($1) }
            start += n
        }
        guard start + length <= b.count else { return nil }
        return (b[i], start..<(start + length), start + length)
    }
}

/// Just enough protobuf to walk a CRX header: varints and length-delimited fields.
enum Protobuf {
    struct Field {
        let number: Int
        let bytes: [UInt8]
    }

    static func fields(_ b: [UInt8]) -> [Field] {
        var out: [Field] = []
        var i = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]
                i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let tag = varint() else { break }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0: guard varint() != nil else { return out }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let length = varint().map(Int.init), i + length <= b.count else { return out }
                out.append(Field(number: number, bytes: Array(b[i..<(i + length)])))
                i += length
            default: return out
            }
        }
        return out
    }
}

/// The folders Chromium can load at launch.
public enum ExtensionFolders {
    /// Leaves out what can't be loaded that way. Chromium's switch takes a comma-separated list, so
    /// a folder with a comma in its path would be read as two, and a missing folder is an error.
    public static func launchable(_ folders: [URL]) -> [URL] {
        folders.filter { folder in
            !folder.path.contains(",") && FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path)
        }
    }
}
