import CoreGraphics
import Foundation

/// Tabs shown side by side (or stacked) in one card. The split lives in its Space and shows as a
/// single row in the sidebar; selecting any of its tabs shows them all, focused on that one.
public struct TabSplit: Codable, Equatable, Sendable, Identifiable {
    public enum Axis: String, Codable, Sendable, CaseIterable {
        /// Panes side by side.
        case horizontal
        /// Panes stacked.
        case vertical

        public var flipped: Axis { self == .horizontal ? .vertical : .horizontal }
    }

    public let id: String
    /// The panes, leading to trailing (or top to bottom).
    public var tabs: [TabID]
    public var axis: Axis
    /// Each pane's share of the card. Sums to 1.
    public var fractions: [Double]

    public static let maxPanes = 4
    /// No pane gets narrower than this share.
    public static let minFraction = 0.15

    public init(id: String = UUID().uuidString, tabs: [TabID], axis: Axis = .horizontal, fractions: [Double]? = nil) {
        self.id = id
        self.tabs = tabs
        self.axis = axis
        self.fractions = fractions ?? Array(repeating: 1 / Double(max(tabs.count, 1)), count: tabs.count)
        normalize()
    }

    /// Keeps one fraction per pane, each at least `minFraction`, summing to 1.
    public mutating func normalize() {
        if fractions.count != tabs.count || fractions.contains(where: { !$0.isFinite || $0 <= 0 }) {
            fractions = Array(repeating: 1 / Double(max(tabs.count, 1)), count: tabs.count)
            return
        }
        let floor = min(Self.minFraction, 1 / Double(max(tabs.count, 1)))
        fractions = fractions.map { max($0, floor) }
        let total = fractions.reduce(0, +)
        fractions = fractions.map { $0 / total }
    }

    public mutating func equalize() {
        fractions = Array(repeating: 1 / Double(max(tabs.count, 1)), count: tabs.count)
    }

    /// Moves the divider after pane `index` by `delta` (a share of the card), within limits.
    public mutating func moveDivider(after index: Int, by delta: Double) {
        guard fractions.indices.contains(index), fractions.indices.contains(index + 1) else { return }
        let pair = fractions[index] + fractions[index + 1]
        let floor = min(Self.minFraction, pair / 2)
        let left = min(max(fractions[index] + delta, floor), pair - floor)
        fractions[index] = left
        fractions[index + 1] = pair - left
    }

    /// Each pane's frame in a card of `size`, with `gap` points between panes.
    public func frames(in size: CGSize, gap: CGFloat) -> [CGRect] {
        let length = axis == .horizontal ? size.width : size.height
        let usable = max(0, length - gap * CGFloat(tabs.count - 1))
        var offset: CGFloat = 0
        return fractions.map { fraction in
            let extent = (usable * CGFloat(fraction)).rounded()
            defer { offset += extent + gap }
            return axis == .horizontal
                ? CGRect(x: offset, y: 0, width: extent, height: size.height)
                : CGRect(x: 0, y: offset, width: size.width, height: extent)
        }
        .enumerated()
        .map { i, rect in
            // The last pane takes up the rounding slack.
            guard i == tabs.count - 1 else { return rect }
            return axis == .horizontal
                ? CGRect(x: rect.minX, y: 0, width: max(0, size.width - rect.minX), height: size.height)
                : CGRect(x: 0, y: rect.minY, width: size.width, height: max(0, size.height - rect.minY))
        }
    }
}

/// Where a tab lands beside a pane.
public enum SplitEdge: String, Codable, Sendable, CaseIterable {
    case leading, trailing, top, bottom

    public var axis: TabSplit.Axis { self == .leading || self == .trailing ? .horizontal : .vertical }
    /// True when the new pane goes after the target.
    public var isAfter: Bool { self == .trailing || self == .bottom }
}

extension Space {
    public func split(containing id: TabID) -> TabSplit? { splits.first { $0.tabs.contains(id) } }

    public func splitIndex(containing id: TabID) -> Int? { splits.firstIndex { $0.tabs.contains(id) } }

    /// The tabs a sidebar row stands for: a split's panes, or just the tab.
    public func group(of id: TabID) -> [TabID] { split(containing: id)?.tabs ?? [id] }
}
