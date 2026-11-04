import Foundation

/// Decides which live pages to tear down to save memory. A sleeping tab keeps its place,
/// title and URL; its page is rebuilt when the user comes back to it.
public struct HibernationPolicy: Sendable, Equatable {
    /// Pages idle longer than this go to sleep.
    public var idleInterval: TimeInterval
    /// Never keep more live pages than this, sleeping the least recently used first.
    public var maxAwake: Int

    public init(idleInterval: TimeInterval = 20 * 60, maxAwake: Int = 6) {
        self.idleInterval = idleInterval
        self.maxAwake = maxAwake
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
}
