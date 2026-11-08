import Foundation
import Observation

/// Receives the engine work that actions imply.
@MainActor
public protocol BrowserEffectHandler: AnyObject {
    func perform(_ effects: [BrowserEffect], store: BrowserStore)
}

/// One tab's live page facts, observed on their own.
@MainActor
@Observable
final class LiveStatus {
    var status = PageStatus()
    /// Apart from the rest: it changes many times a load, and only the loading line shows it.
    var progress = 0.0
}

/// The single source of truth the UI observes. All mutations go through `send(_:)`.
@MainActor
@Observable
public final class BrowserStore {
    public private(set) var state: BrowserState
    /// Live page facts (loading, back/forward), each tab's on its own, because they change many
    /// times a second while a page loads and only what shows that tab should hear of it.
    @ObservationIgnored private var pages: [TabID: LiveStatus] = [:]

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

    public func status(of id: TabID) -> PageStatus { live(id).status }

    public func progress(of id: TabID) -> Double { live(id).progress }

    public func setProgress(_ id: TabID, _ progress: Double) { live(id).progress = progress }

    private func live(_ id: TabID) -> LiveStatus {
        if let live = pages[id] { return live }
        let live = LiveStatus()
        pages[id] = live
        return live
    }

    /// Called by the engine side when a page's live status changes.
    public func updateStatus(_ id: TabID, _ update: (inout PageStatus) -> Void) {
        let live = live(id)
        var status = live.status
        update(&status)
        if live.status != status { live.status = status }
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
