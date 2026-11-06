import Foundation
import Observation
import SkylightCore
import SkylightEngine
import SkylightKit

/// Saved addresses and cards. Like passwords, they live in the Keychain, and a page sees one only
/// when you choose it in Skylight's own UI. A card also asks for Touch ID or your password first,
/// and goes only to a secure page.
@MainActor
@Observable
public final class AutofillService {
    /// Everything saved, by profile. Card numbers are left out; a fill reads one when it needs it.
    public private(set) var saved: [ProfileID: AutofillData] = [:]

    @ObservationIgnored private let store: AutofillStore
    @ObservationIgnored private let toasts: ToastCenter
    /// The profiles to list things for.
    @ObservationIgnored var profiles: () -> [ProfileID] = { [.standard] }

    public init(store: AutofillStore, toasts: ToastCenter) {
        self.store = store
        self.toasts = toasts
    }

    public func reload() {
        var found: [ProfileID: AutofillData] = [:]
        for profile in profiles() {
            guard var data = try? store.load(profile) else { continue }
            data.cards = data.cards.map(\.withoutNumber)
            found[profile] = data
        }
        saved = found
    }

    public func data(in profile: ProfileID) -> AutofillData { saved[profile] ?? AutofillData() }

    /// Adds imported addresses and cards, and returns how many of each were new.
    public func merge(_ found: AutofillData, into profile: ProfileID) -> (addresses: Int, cards: Int) {
        guard !found.isEmpty, var data = try? store.load(profile) else { return (0, 0) }
        let added = data.merge(found)
        guard (try? store.save(data, in: profile)) != nil else { return (0, 0) }
        reload()
        return added
    }

    /// Moves a deleted profile's addresses and cards to the default profile.
    func move(from profile: ProfileID) {
        guard let leaving = try? store.load(profile), !leaving.isEmpty else { return }
        guard var kept = try? store.load(.standard) else { return }
        _ = kept.merge(leaving)
        guard (try? store.save(kept, in: .standard)) != nil else { return }
        try? store.save(AutofillData(), in: profile)
        reload()
    }

    public func remove(address: AutofillAddress, from profile: ProfileID) {
        edit(profile) { $0.addresses.removeAll { $0.id == address.id } }
    }

    public func remove(card: AutofillCard, from profile: ProfileID) {
        edit(profile) { $0.cards.removeAll { $0.id == card.id } }
    }

    private func edit(_ profile: ProfileID, _ change: (inout AutofillData) -> Void) {
        guard var data = try? store.load(profile) else { return }
        change(&data)
        try? store.save(data, in: profile)
        reload()
    }

    public func fill(_ address: AutofillAddress, in page: WebPage, url: URL?) {
        guard AutofillScript.accepts(url, card: false) else { return toasts.show("Addresses fill on web pages only", symbol: "person.text.rectangle") }
        run(address.fields, in: page)
    }

    /// Fills a card that `currentURL` still shows after you've confirmed it's you, so a page can't
    /// move on while the prompt is up and collect the number somewhere else.
    public func fill(_ card: AutofillCard, in page: WebPage, profile: ProfileID, confirm: (String) async -> Bool, currentURL: () -> URL?) async {
        let start = currentURL()
        guard AutofillScript.accepts(start, card: true) else { return toasts.show("Cards fill on secure pages only", symbol: "lock") }
        guard await confirm("fill your card ending in \(card.last4)"), currentURL() == start,
              let full = try? store.load(profile).cards.first(where: { $0.id == card.id }) else { return }
        run(full.fields, in: page)
    }

    private func run(_ fields: [String: String], in page: WebPage) {
        Task { [toasts] in
            let count = (try? await page.evaluate(AutofillScript.fill(fields)))?.intValue ?? 0
            if count == 0 { toasts.show("Nothing to fill on this page", symbol: "person.text.rectangle") }
        }
    }
}
