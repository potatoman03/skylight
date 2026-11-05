import CoreGraphics

/// Moving through a menu with the arrow keys and the pointer.
public enum MenuNavigation {
    /// The next row you can use, `offset` (1 or -1) from `current`, wrapping at the ends and
    /// skipping disabled rows. From no row, down starts at the top and up at the bottom.
    public static func step(from current: Int?, by offset: Int, enabled: [Bool]) -> Int? {
        let count = enabled.count
        var index = current ?? (offset > 0 ? -1 : count)
        for _ in 0..<count {
            index = (index + offset + count) % count
            if enabled[index] { return index }
        }
        return current
    }

    /// The row at `y` down a menu, numbered across its sections, or nil on a divider or the
    /// padding. `sections` holds each section's row count.
    public static func row(at y: CGFloat, sections: [Int], inset: CGFloat, rowHeight: CGFloat, divider: CGFloat) -> Int? {
        var top = inset, first = 0
        for (index, count) in sections.enumerated() {
            if index > 0 { top += divider }
            let bottom = top + CGFloat(count) * rowHeight
            if y >= top, y < bottom { return first + Int((y - top) / rowHeight) }
            top = bottom
            first += count
        }
        return nil
    }

    /// Whether `point` is in the funnel from `apex` to the submenu's near edge: a pointer going
    /// from a row to its submenu crosses other rows, and inside the funnel those don't count.
    public static func isInFunnel(_ point: CGPoint, from apex: CGPoint, toEdgeAtX x: CGFloat, top: CGFloat, bottom: CGFloat) -> Bool {
        func side(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (point.x - b.x) * (a.y - b.y) - (a.x - b.x) * (point.y - b.y)
        }
        let corners = (CGPoint(x: x, y: top), CGPoint(x: x, y: bottom))
        let sides = [side(apex, corners.0), side(corners.0, corners.1), side(corners.1, apex)]
        return sides.allSatisfy { $0 >= 0 } || sides.allSatisfy { $0 <= 0 }
    }
}
