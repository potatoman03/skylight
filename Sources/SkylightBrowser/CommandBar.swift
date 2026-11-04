import Foundation
import Observation
import SkylightCore

/// One row in the command bar.
public struct CommandItem: Identifiable {
    public enum Kind: Sendable { case address, search, tab, command }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let symbol: String
    public let faviconURL: URL?
    /// The site the row leads to, so it can show the site's logo.
    public let pageURL: URL?
    public let perform: @MainActor () -> Void

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, symbol: String,
                faviconURL: URL? = nil, pageURL: URL? = nil, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.faviconURL = faviconURL
        self.pageURL = pageURL
        self.perform = perform
    }
}

/// Supplies rows for a query. `Browser` is the real one; tests can pass their own.
@MainActor
public protocol CommandSource: AnyObject {
    func commandItems(for query: String, mode: CommandBarModel.Mode) -> [CommandItem]
}

/// State of the command bar (⌘T / ⌘L): what's typed, what's highlighted.
@MainActor
@Observable
public final class CommandBarModel {
    public enum Mode: Equatable, Sendable {
        /// ⌘T: Enter opens a new tab.
        case newTab
        /// ⌘L: Enter navigates the selected tab.
        case editCurrent
        /// Enter opens a new tab beside the selected one, in a split.
        case split
    }

    public private(set) var isPresented = false
    public private(set) var mode: Mode = .newTab
    public var query = "" { didSet { if query != oldValue { selection = 0 } } }
    public var selection = 0
    @ObservationIgnored public weak var source: CommandSource?

    public init() {}

    public var items: [CommandItem] { source?.commandItems(for: query, mode: mode) ?? [] }

    public func present(_ mode: Mode, query: String = "") {
        self.mode = mode
        self.query = query
        selection = 0
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
    }

    public func moveSelection(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    public func submit(_ item: CommandItem? = nil) {
        let list = items
        guard let chosen = item ?? (list.indices.contains(selection) ? list[selection] : nil) else { return }
        dismiss()
        chosen.perform()
    }
}
