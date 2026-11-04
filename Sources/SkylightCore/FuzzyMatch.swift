import Foundation

/// Ranks text against a query: prefix beats word start beats substring beats scattered letters.
public enum FuzzyMatch {
    public static func score(_ query: String, in text: String) -> Int? {
        let q = query.lowercased(), t = text.lowercased()
        guard !q.isEmpty else { return 1 }
        if t.hasPrefix(q) { return 1000 - t.count }
        if t.contains(" " + q) || t.contains("." + q) || t.contains("/" + q) { return 700 - t.count }
        if t.contains(q) { return 500 - t.count }
        var it = t.makeIterator()
        for ch in q {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return nil }
        }
        return 100 - t.count
    }

    /// How well a tab matches: by title, or a little less by address. Nil when neither matches.
    public static func score(_ query: String, title: String, url: String) -> Int? {
        let byTitle = score(query, in: title)
        let byURL = score(query, in: url).map { $0 - 50 }
        switch (byTitle, byURL) {
        case let (title?, url?): return max(title, url)
        case let (title, url): return title ?? url
        }
    }
}
