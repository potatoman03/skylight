import Foundation

/// Decides which live pages to tear down to save memory. A sleeping tab keeps its place,
/// title and URL; its page is rebuilt when the user comes back to it.
public struct HibernationPolicy: Sendable, Equatable {
    /// Pages idle longer than this go to sleep.
    public var idleInterval: TimeInterval
    /// Never keep more live pages than this, sleeping the least recently used first.
    public var maxAwake: Int

    public init(idleInterval: TimeInterval = 4 * 60 * 60, maxAwake: Int = 16) {
        self.idleInterval = idleInterval
        self.maxAwake = maxAwake
    }

    /// Going back to a sleeping tab means loading it from scratch, but a site like Google Docs
    /// holds over 400 MB while it's up, so a page per gigabyte of memory, within limits. If the Mac
    /// still runs short, `pagesToShed` gives memory back.
    public init(memoryBytes: UInt64) {
        let gigabytes = Int(memoryBytes / (1 << 30))
        self.init(maxAwake: min(max(gigabytes, 8), 24))
    }

    /// - Parameters:
    ///   - awake: live pages and when each was last active.
    ///   - protected: pages that must stay (the visible tab in each Space, pages playing media).
    public func pagesToSleep(awake: [TabID: Date], protected: Set<TabID>, now: Date) -> [TabID] {
        let candidates = awake.filter { !protected.contains($0.key) }
        var sleep = Set(candidates.filter { now.timeIntervalSince($0.value) > idleInterval }.keys)

        let remaining = awake.count - sleep.count
        if remaining > maxAwake {
            let lru = candidates
                .filter { !sleep.contains($0.key) }
                .sorted { $0.value < $1.value }
                .prefix(remaining - maxAwake)
            sleep.formUnion(lru.map(\.key))
        }
        return sleep.sorted { (awake[$0] ?? .distantPast) < (awake[$1] ?? .distantPast) }
    }

    /// When the Mac is short of memory: the older half of the pages that may sleep.
    public func pagesToShed(awake: [TabID: Date], protected: Set<TabID>) -> [TabID] {
        let candidates = awake.filter { !protected.contains($0.key) }.sorted { $0.value < $1.value }
        return candidates.prefix((candidates.count + 1) / 2).map(\.key)
    }
}
