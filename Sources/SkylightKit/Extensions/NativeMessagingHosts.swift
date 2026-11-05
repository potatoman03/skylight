import Foundation

/// The apps extensions talk to: 1Password, Bitwarden, Apple Passwords and the like each register a
/// host with the browsers they know when you install them, never with Skylight. Chromium looks
/// for hosts only in its own folder, so Skylight links the ones registered for other Chromium
/// browsers into it. Extensions installed from the Chrome Web Store have the same ids here, so the
/// hosts accept them.
public enum NativeMessagingHosts {
    /// Where other Chromium browsers keep their hosts, most trusted first.
    public static func sources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let system = [
            "/Library/Google/Chrome/NativeMessagingHosts",
            "/Library/Application Support/Chromium/NativeMessagingHosts",
            "/Library/Microsoft/Edge/NativeMessagingHosts",
            "/Library/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let user = [
            "Google/Chrome", "Chromium", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Vivaldi",
        ].map { home.appending(path: "Library/Application Support/\($0)/NativeMessagingHosts", directoryHint: .isDirectory) }
        return user + system
    }

    /// Links into `directory` each host registered in `sources` that Skylight doesn't have yet, and
    /// drops links whose host has since been uninstalled. Returns the hosts it linked.
    @discardableResult
    public static func adopt(from sources: [URL] = sources(), into directory: URL) -> [String] {
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)

        // A link to a host that's gone would only fail later, when an extension calls it.
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let link = directory.appending(path: name)
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil, !files.fileExists(atPath: link.path) {
                try? files.removeItem(at: link)
            }
        }

        var adopted: [String] = []
        for source in sources {
            for name in (try? files.contentsOfDirectory(atPath: source.path)) ?? [] where name.hasSuffix(".json") {
                let target = directory.appending(path: name)
                let manifest = source.appending(path: name)
                // Skylight's own (or one already linked from an earlier source) wins.
                guard !files.fileExists(atPath: target.path), isHost(manifest, named: String(name.dropLast(5))) else { continue }
                if (try? files.createSymbolicLink(at: target, withDestinationURL: manifest)) != nil { adopted.append(name) }
            }
        }
        return adopted
    }

    /// A host manifest Chromium would accept: its name matches the file, it runs a program by an
    /// absolute path over stdio, and it names the extensions it serves.
    static func isHost(_ url: URL, named name: String) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["name"] as? String == name, json["type"] as? String == "stdio",
              let path = json["path"] as? String, path.hasPrefix("/"),
              let origins = json["allowed_origins"] as? [String], !origins.isEmpty else { return false }
        return origins.allSatisfy { $0.hasPrefix("chrome-extension://") }
    }
}
