import CryptoKit
import Foundation

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

    /// Permissions people should know about before installing, in plain words.
    public var warnings: [String] {
        var out: [String] = []
        let hosts = hostPermissions + permissions.filter { $0.contains("://") || $0 == "<all_urls>" }
        if hosts.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }) {
            out.append("Read and change everything on every website")
        } else if !hosts.isEmpty {
            out.append("Read and change your data on \(hosts.count == 1 ? "one site" : "\(hosts.count) sites")")
        }
        let named: [String: String] = [
            "tabs": "See your open tabs and their addresses", "history": "Read your browsing history",
            "bookmarks": "Read and change your bookmarks", "cookies": "Read and change cookies",
            "downloads": "Manage your downloads", "clipboardRead": "Read what you copy",
            "nativeMessaging": "Talk to apps on your Mac", "webRequest": "Watch your network requests",
            "debugger": "Debug and control pages", "management": "Manage your other extensions",
        ]
        out += permissions.compactMap { named[$0] }
        return out
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

    /// The update service's direct download of the current CRX.
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
    /// The developer key that the extension's id derives from.
    public let publicKey: Data?

    public enum Failure: Error, LocalizedError, Equatable {
        case notCRX
        case unsupportedVersion(UInt32)

        public var errorDescription: String? {
            switch self {
            case .notCRX: "The download isn't a Chrome extension."
            case let .unsupportedVersion(v): "That extension uses package format \(v), which Skylight can't open."
            }
        }
    }

    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] else { throw Failure.notCRX }  // "Cr24"
        let version = Self.uint32(bytes, 4)
        guard version == 3 else { throw Failure.unsupportedVersion(version) }
        let headerSize = Int(Self.uint32(bytes, 8))
        guard 12 + headerSize <= bytes.count else { throw Failure.notCRX }
        let header = Array(bytes[12..<(12 + headerSize)])
        archive = Data(bytes[(12 + headerSize)...])
        publicKey = Self.developerKey(in: header)
    }

    static func uint32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// The header is a protobuf `CrxFileHeader`. Field 2 holds RSA proofs, field 10000 the signed
    /// data whose field 1 is the id the store assigned. The developer key is the proof whose
    /// key hashes to that id.
    static func developerKey(in header: [UInt8]) -> Data? {
        let fields = Protobuf.fields(header)
        let keys = fields.filter { $0.number == 2 }.compactMap { proof in
            Protobuf.fields(proof.bytes).first { $0.number == 1 }.map { Data($0.bytes) }
        }
        if let signed = fields.first(where: { $0.number == 10000 }),
           let idBytes = Protobuf.fields(signed.bytes).first(where: { $0.number == 1 })?.bytes {
            let alphabet = Array("abcdefghijklmnop")
            let id = String(idBytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 0xF)]] })
            if let match = keys.first(where: { ExtensionID.from(publicKey: $0) == id }) { return match }
        }
        return keys.first
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
