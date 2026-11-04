import Foundation
import Observation

/// Receives the engine work that actions imply.
@MainActor
public protocol BrowserEffectHandler: AnyObject {
    func perform(_ effects: [BrowserEffect], store: BrowserStore)
}

/// The single source of truth the UI observes. All mutations go through `send(_:)`.
@MainActor
@Observable
public final class BrowserStore {
    public private(set) var state: BrowserState
    /// Live page facts (loading, back/forward), keyed by tab. Not persisted.
    public private(set) var pages: [TabID: PageStatus] = [:]

    @ObservationIgnored public weak var effectHandler: BrowserEffectHandler?
    @ObservationIgnored private let persistence: StateStore
    @ObservationIgnored private let env: ReducerEnvironment
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let saveDelay: Duration

    public init(persistence: StateStore, env: ReducerEnvironment = ReducerEnvironment(), saveDelay: Duration = .milliseconds(400)) {
        self.persistence = persistence
        self.env = env
        self.saveDelay = saveDelay
        self.state = (try? persistence.load()) ?? .initial()
    }

    @discardableResult
    public func send(_ action: BrowserAction) -> ReduceResult {
        var next = state
        let result = BrowserReducer.reduce(&next, action, env: env)
        guard result.applied else { return result }
        if next != state {
            state = next
            scheduleSave()
        }
        for case let .discardPage(id) in result.effects where state.tabs[id] == nil { pages[id] = nil }
        effectHandler?.perform(result.effects, store: self)
        return result
    }

    public func status(of id: TabID) -> PageStatus { pages[id] ?? PageStatus() }

    /// Called by the engine side when a page's live status changes.
    public func updateStatus(_ id: TabID, _ update: (inout PageStatus) -> Void) {
        var s = pages[id] ?? PageStatus()
        update(&s)
        if pages[id] != s { pages[id] = s }
    }

    // MARK: - Persistence

    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        try? persistence.save(state)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            try? self.persistence.save(self.state)
        }
    }
}
