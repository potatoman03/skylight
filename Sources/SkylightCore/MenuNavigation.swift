/// Moving through a menu with the arrow keys.
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
}
