import Foundation

/// The parts of the sidebar that can change places. Pinned and Today swap freely; favorites sit
/// outside the scrolling list, so they go at either end of it, never between the two.
public enum SidebarSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case favorites, pinned, today

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .favorites: "Favorites"
        case .pinned: "Pinned tabs"
        case .today: "Today"
        }
    }

    public static let standardOrder: [SidebarSection] = [.favorites, .pinned, .today]
}

extension Array where Element == SidebarSection {
    public var favoritesLast: Bool { last == .favorites }

    public var todayFirst: Bool { (firstIndex(of: .today) ?? 0) < (firstIndex(of: .pinned) ?? 0) }

    /// Each section once, with favorites at an end. A hand-edited file can hold anything.
    public var normalized: [SidebarSection] {
        var seen = Set<SidebarSection>()
        var order = filter { seen.insert($0).inserted }
        order += SidebarSection.standardOrder.filter { !seen.contains($0) }
        if order[1] == .favorites { order.swapAt(0, 1) }
        return order
    }

    /// The order with `section` moved up (negative) or down (positive). Favorites jump to the far
    /// end, since they can't sit between the others.
    public func moving(_ section: SidebarSection, by offset: Int) -> [SidebarSection] {
        var tabs = filter { $0 != .favorites }
        var favoritesLast = favoritesLast
        if section == .favorites {
            favoritesLast = offset > 0
        } else if let i = tabs.firstIndex(of: section), tabs.indices.contains(i + offset.signum()) {
            tabs.swapAt(i, i + offset.signum())
        }
        return favoritesLast ? tabs + [.favorites] : [.favorites] + tabs
    }
}
