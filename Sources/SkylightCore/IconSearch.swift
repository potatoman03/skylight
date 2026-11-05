import Foundation

/// What can be a Space's icon, and finding one by name. Symbols are a chosen few, since macOS has
/// no list of them; emoji are every one Unicode names, so search can reach all of them.
public enum IconSearch {
    public struct Symbol: Hashable, Sendable {
        public let symbol: String
        public let name: String

        init(_ symbol: String, _ name: String) {
            self.symbol = symbol
            self.name = name
        }
    }

    public static let symbols: [Symbol] = [
        Symbol("sun.max", "Sun"), Symbol("moon", "Moon"), Symbol("briefcase", "Work"), Symbol("house", "Home"),
        Symbol("book", "Reading"), Symbol("star", "Star"), Symbol("heart", "Heart"), Symbol("leaf", "Leaf"),
        Symbol("bolt", "Bolt"), Symbol("flame", "Flame"), Symbol("globe.americas", "Globe"),
        Symbol("music.note", "Music"), Symbol("graduationcap", "School"), Symbol("cart", "Shopping"),
        Symbol("paintpalette", "Art"), Symbol("chevron.left.forwardslash.chevron.right", "Code"),
        Symbol("sparkles", "Sparkles"), Symbol("cloud", "Cloud"), Symbol("mountain.2", "Mountains"),
        Symbol("tree", "Tree"), Symbol("pawprint", "Pets"), Symbol("airplane", "Travel"), Symbol("car", "Car"),
        Symbol("bicycle", "Bike"), Symbol("camera", "Photos"), Symbol("film", "Movies"),
        Symbol("headphones", "Listening"), Symbol("gamecontroller", "Games"), Symbol("dumbbell", "Fitness"),
        Symbol("fork.knife", "Food"), Symbol("cup.and.saucer", "Coffee"), Symbol("building.2", "Office"),
        Symbol("banknote", "Money"), Symbol("chart.bar", "Charts"), Symbol("hammer", "Tools"),
        Symbol("terminal", "Terminal"), Symbol("flask", "Science"), Symbol("lightbulb", "Ideas"),
        Symbol("calendar", "Calendar"),
    ]

    public static let featuredEmoji = [
        "😀", "😎", "🤓", "🧠", "💼", "🏠", "📚", "🎓",
        "🎨", "🎵", "🎮", "🎬", "✈️", "🏝️", "🏔️", "🌿",
        "🌸", "🔥", "⚡️", "⭐️", "🌙", "☀️", "❤️", "🚀",
        "🧪", "💡", "💰", "📈", "🛒", "🍕", "☕️", "🐾",
    ]

    /// Words people search for that aren't in Unicode's names: ☕ is "hot beverage".
    private static let emojiAliases: [String: [String]] = [
        "coffee": ["☕️"], "happy": ["😀", "😊"], "sad": ["😢"], "work": ["💼"], "home": ["🏠"],
        "money": ["💰"], "study": ["📚"], "school": ["🎓"], "travel": ["✈️"], "game": ["🎮"], "idea": ["💡"],
    ]

    private struct Named: Sendable {
        let emoji: String
        let words: [String]
    }

    private static let named: [Named] = {
        // Skin tones and flag letters only mean something joined to another emoji.
        let ranges: [ClosedRange<UInt32>] = [0x2600...0x27BF, 0x1F300...0x1FAFF]
        return ranges.flatMap { $0 }.compactMap { value in
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji, !scalar.properties.isEmojiModifier,
                  let name = scalar.properties.name else { return nil }
            // Some draw as plain text unless asked for in color.
            let emoji = String(scalar) + (scalar.properties.isEmojiPresentation ? "" : "\u{FE0F}")
            return Named(emoji: emoji, words: words(name))
        }
    }()

    public static func symbols(matching query: String) -> [Symbol] {
        let terms = words(query)
        guard !terms.isEmpty else { return symbols }
        return symbols.filter { matches(terms, in: words($0.name) + words($0.symbol)) }
    }

    /// Emoji whose names have every word typed, the ones you'd likely mean first, up to `limit`.
    public static func emoji(matching query: String, limit: Int = 40) -> [String] {
        let terms = words(query)
        guard !terms.isEmpty else { return featuredEmoji }
        let aliases = terms.count == 1 ? emojiAliases[terms[0]] ?? [] : []
        let found = named.filter { matches(terms, in: $0.words) }.map(\.emoji)
        var seen = Set<String>()
        return (aliases + found).filter { seen.insert($0.replacingOccurrences(of: "\u{FE0F}", with: "")).inserted }.prefix(limit).map(\.self)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// "mou" finds "mountain": search narrows as you type.
    private static func matches(_ terms: [String], in words: [String]) -> Bool {
        terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
    }
}
