import Foundation

/// A group of today's tabs that Tidy turns into a folder.
public struct TidyGroup: Equatable, Sendable {
    public var name: String
    public var tabs: [TabID]

    public init(name: String, tabs: [TabID]) {
        self.name = name
        self.tabs = tabs
    }
}

/// Tidy gathers a Space's loose tabs into folders: by whatever the on-device model makes of your
/// instruction, or by site when there's no model.
public enum Tidy {
    /// The tabs Tidy may move: today's, except those in splits.
    public static func candidates(_ space: Space) -> [TabID] {
        space.today.filter { space.split(containing: $0) == nil }
    }

    /// Two or more tabs from one site make a folder named for the site.
    public static func bySite(_ tabs: [Tab]) -> [TidyGroup] {
        var order: [String] = []
        var bySite: [String: [TabID]] = [:]
        for tab in tabs {
            guard let site = site(tab.url) else { continue }
            if bySite[site] == nil { order.append(site) }
            bySite[site, default: []].append(tab.id)
        }
        return clean(order.map { TidyGroup(name: $0.prefix(1).uppercased() + $0.dropFirst(), tabs: bySite[$0]!) }, allowed: tabs.map(\.id))
    }

    /// What a model proposed, made safe to apply: only tabs it was shown, each in one group, groups
    /// of two or more, with short names.
    public static func clean(_ groups: [TidyGroup], allowed: [TabID]) -> [TidyGroup] {
        let allowed = Set(allowed)
        var taken = Set<TabID>()
        return groups.compactMap { group in
            let tabs = group.tabs.filter { allowed.contains($0) && taken.insert($0).inserted }
            let name = String(group.name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).prefix(32))
            guard tabs.count > 1, !name.isEmpty else { return nil }
            return TidyGroup(name: name, tabs: tabs)
        }
    }

    /// The site's name: `github` for gist.github.com, `bbc` for www.bbc.co.uk.
    static func site(_ url: URL) -> String? {
        guard var parts = url.host(percentEncoded: false)?.lowercased().split(separator: "."), parts.count > 1 else { return nil }
        parts.removeLast()
        // Second-level country domains: co.uk, com.au.
        if parts.count > 1, let last = parts.last, ["co", "com", "org", "net", "ac", "gov"].contains(last) { parts.removeLast() }
        return parts.last.map(String.init)
    }
}
