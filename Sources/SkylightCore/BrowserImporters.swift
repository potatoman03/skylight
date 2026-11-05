import Foundation

/// Reads Spaces, pinned tabs and favorites out of other browsers' files.
public enum BrowserImporters {
    public enum ImportError: LocalizedError {
        case notFound(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case let .notFound(name): "\(name) isn't installed, or has nothing to import."
            case let .unreadable(name): "Couldn't read \(name)'s data."
            }
        }
    }

    public static var arcFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Arc/StorableSidebar.json")
    }

    // MARK: - Arc

    /// Arc's `StorableSidebar.json`. Spaces and their pinned tabs (folders flattened), the
    /// favorites, and which profile each belongs to. Unpinned tabs are left behind; they'd be
    /// archived soon anyway.
    public static func arc(_ data: Data) throws -> BrowserImport {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil })
        else { throw ImportError.unreadable("Arc") }

        // Arc stores maps as flat [key, value, key, value] lists.
        let items = Dictionary((main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            .compactMap { item in (item["id"] as? String).map { ($0, item) } }, uniquingKeysWith: { a, _ in a })

        func links(under containerID: String, depth: Int = 0) -> [BrowserImport.Link] {
            guard depth < 8, let item = items[containerID] else { return [] }
            return (item["childrenIds"] as? [String] ?? []).flatMap { childID -> [BrowserImport.Link] in
                guard let child = items[childID], let data = child["data"] as? [String: Any] else { return [] }
                if let tab = data["tab"] as? [String: Any] {
                    guard let raw = tab["savedURL"] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true
                    else { return [] }
                    let title = (child["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host() ?? raw
                    return [BrowserImport.Link(url: url, title: title)]
                }
                return links(under: childID, depth: depth + 1) // Folders.
            }
        }

        var spaces: [BrowserImport.ImportedSpace] = []
        for (n, space) in (main["spaces"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }).enumerated() {
            let ids = space["containerIDs"] as? [Any] ?? []
            guard let i = ids.firstIndex(where: { ($0 as? String) == "pinned" }), i + 1 < ids.count,
                  let pinnedID = ids[i + 1] as? String else { continue }
            let info = space["customInfo"] as? [String: Any]
            spaces.append(.init(name: (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space \(n + 1)",
                                icon: arcIcon(info?["iconType"] as? [String: Any]),
                                hue: arcHue(info), pinned: links(under: pinnedID), sourceProfile: arcProfile(space["profile"])))
        }

        // Each profile has its own favorites: a flat [profile, container, profile, container] list.
        var favorites: [BrowserImport.Link] = []
        var owner: String?
        for entry in main["topAppsContainerIDs"] as? [Any] ?? [] {
            guard let id = entry as? String else {
                owner = arcProfile(entry)
                continue
            }
            let found = links(under: id)
            if let i = spaces.firstIndex(where: { owner != nil && $0.sourceProfile == owner }) {
                spaces[i].favorites += found
            } else {
                favorites += found
            }
        }

        let result = BrowserImport(source: "Arc", spaces: spaces, favorites: favorites)
        if result.isEmpty { throw ImportError.notFound("Arc") }
        return result
    }

    /// The folder in Arc's `{"custom":{"_0":{"directoryBasename":"Profile 2"}}}`. Its default
    /// profile, `{"default":true}`, has none.
    static func arcProfile(_ value: Any?) -> String? {
        guard let custom = (value as? [String: Any])?["custom"] as? [String: Any],
              let folder = (custom["_0"] as? [String: Any])?["directoryBasename"] as? String,
              !folder.isEmpty, folder != "Default", folder != "..", !folder.contains("/")
        else { return nil }
        return folder
    }

    /// Arc's emoji icons carry over; its named icons map to the closest SF Symbol.
    static func arcIcon(_ icon: [String: Any]?) -> String? {
        guard let icon else { return nil }
        if let emoji = (icon["emoji_v2"] ?? icon["emoji"]) as? String, !emoji.isEmpty { return emoji }
        let names = ["planet": "globe.americas", "star": "star", "heart": "heart", "bolt": "bolt", "book": "book",
                     "briefcase": "briefcase", "code": "chevron.left.forwardslash.chevron.right", "moon": "moon",
                     "sun": "sun.max", "leaf": "leaf", "flame": "flame", "music": "music.note", "house": "house"]
        return (icon["icon"] as? String).flatMap { names[$0] }
    }

    static func arcHue(_ info: [String: Any]?) -> Double? {
        guard let theme = info?["windowTheme"] as? [String: Any],
              let palette = theme["primaryColorPalette"] as? [String: Any],
              let color = palette["midTone"] as? [String: Any],
              let r = color["red"] as? Double, let g = color["green"] as? Double, let b = color["blue"] as? Double
        else { return nil }
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        // Grey themes have no hue worth keeping.
        guard delta > 0.04 else { return nil }
        var h: Double
        if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = (b - r) / delta + 2 }
        else { h = (r - g) / delta + 4 }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    // MARK: - Chromium (Chrome, Aside, Brave, Edge, ...)

    /// What a Chromium browser calls its profiles, by folder, from its `Local State` file.
    public static func chromiumProfileNames(_ data: Data) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    /// A Chromium `Bookmarks` file. Loose links on the bookmarks bar become favorites (up to
    /// eight). Each folder on the bar becomes a Space, the way Aside shows folders as sidebar
    /// sections. Everything else lands in a Space named after the browser.
    public static func chromium(_ data: Data, browser: String) throws -> BrowserImport {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw ImportError.unreadable(browser) }

        func link(_ node: [String: Any]) -> BrowserImport.Link? {
            guard let raw = node["url"] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
            let name = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return BrowserImport.Link(url: url, title: name ?? url.host() ?? raw)
        }

        func links(_ node: Any?, depth: Int = 0) -> [BrowserImport.Link] {
            guard depth < 8, let node = node as? [String: Any] else { return [] }
            if node["type"] as? String == "url" { return link(node).map { [$0] } ?? [] }
            return (node["children"] as? [Any] ?? []).flatMap { links($0, depth: depth + 1) }
        }

        let bar = (roots["bookmark_bar"] as? [String: Any])?["children"] as? [Any] ?? []
        var loose: [BrowserImport.Link] = []
        var folders: [BrowserImport.ImportedSpace] = []
        for case let node as [String: Any] in bar {
            if node["type"] as? String == "url" {
                if let link = link(node) { loose.append(link) }
            } else if folders.count < 8 {
                let pinned = Array(links(node).prefix(80))
                guard !pinned.isEmpty else { continue }
                let name = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Folder \(folders.count + 1)"
                folders.append(.init(name: name, icon: "folder", pinned: pinned))
            } else {
                loose += links(node)
            }
        }

        let rest = Array((loose.dropFirst(8) + links(roots["other"]) + links(roots["synced"])).prefix(80))
        let spaces = folders + (rest.isEmpty ? [] : [.init(name: browser, icon: "bookmark", pinned: rest)])
        let result = BrowserImport(source: browser, spaces: spaces, favorites: Array(loose.prefix(8)))
        if result.isEmpty { throw ImportError.notFound(browser) }
        return result
    }
}
