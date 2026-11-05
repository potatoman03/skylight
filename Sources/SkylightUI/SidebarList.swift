import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's list, line by line, top to bottom. It's our own rather than a `List`: an outline
/// view only makes room under a drag it started itself, and throws if SwiftUI changes its rows
/// mid-drag. Here the rows slide apart under a dragged tab, wherever it came from.
struct SidebarLines {
    /// The runs of rows a tab can land among.
    enum Box: Hashable {
        case pinned, today
        case folder(String)

        var isFolder: Bool { if case .folder = self { true } else { false } }
    }

    struct Line: Identifiable {
        enum Kind {
            case spaceHeader
            case folder(TabFolder)
            /// A tab, or a split's tabs, the `index`th row of its box.
            case row([TabID], box: Box, index: Int)
            /// An empty box's line: says what it's for and takes drops.
            case hint(String, TabDropTarget)
            /// Only when Today comes first; otherwise the Space's header stands over pinned tabs.
            case pinnedHeader
            case todayHeader
            case newTab
        }

        let id: String
        let kind: Kind
    }

    private(set) var lines: [Line] = []
    /// Where each box's rows are in `lines`.
    private(set) var boxes: [Box: Range<Int>] = [:]
    /// The box that ends the list, where a drop below every line lands.
    private let lastBox: Box

    init(space: Space, showsNewTab: Bool, todayFirst: Bool = false, showsHints: Bool = true) {
        lastBox = todayFirst ? .pinned : .today
        add("header.space", .spaceHeader)
        if todayFirst {
            addToday(space, showsNewTab: showsNewTab)
            let empty = space.pinned.isEmpty && space.folders.isEmpty
            if !empty || showsHints { add("header.pinned", .pinnedHeader) }
            addPinned(space)
        } else {
            addPinned(space)
            addToday(space, showsNewTab: showsNewTab)
        }
    }

    private mutating func addPinned(_ space: Space) {
        for folder in space.folders {
            add("folder.\(folder.id)", .folder(folder))
            addRows(folder.isOpen ? folder.tabs.map { [$0] } : [], in: .folder(folder.id), space: space)
            if folder.isOpen, folder.tabs.isEmpty {
                add("hint.\(folder.id)", .hint("Drag tabs here", .folder(folder.id, index: 0)))
            }
        }
        // Pinned tabs in folders show in their folders.
        addRows(SidebarRows.make(space.loosePinned, space: space), in: .pinned, space: space)
        if space.pinned.isEmpty, space.folders.isEmpty {
            add("hint.pinned", .hint("Drag tabs here to pin them", .section(.pinned, row: 0)))
        }
    }

    private mutating func addToday(_ space: Space, showsNewTab: Bool) {
        add("header.today", .todayHeader)
        if showsNewTab { add("new-tab", .newTab) }
        addRows(SidebarRows.make(space.today, space: space), in: .today, space: space)
    }

    private mutating func add(_ id: String, _ kind: Line.Kind) {
        lines.append(Line(id: id, kind: kind))
    }

    private mutating func addRows(_ rows: [[TabID]], in box: Box, space: Space) {
        let start = lines.count
        for (index, row) in rows.enumerated() {
            let split = row.count > 1 ? space.split(containing: row[0]) : nil
            add(split.map { "split.\($0.id)" } ?? "tab.\(row[0])", .row(row, box: box, index: index))
        }
        boxes[box] = start..<lines.count
    }

    /// The row a tab is in.
    func line(holding tab: TabID) -> Int? {
        lines.firstIndex { line in
            if case let .row(ids, _, _) = line.kind { ids.contains(tab) } else { false }
        }
    }

    /// What dropping at `y` would do. The lines are hit-tested as if `hidden` were gone, as it is
    /// on screen, but before any gap opens: the gap then opens under the pointer, and stays put
    /// while the pointer is in it.
    func hover(at y: CGFloat, frames: [String: CGRect], hidden: Int?, dragging tab: TabID?) -> SidebarHover? {
        let lift = hidden.flatMap { frames[lines[$0].id]?.height } ?? 0
        for (index, line) in lines.enumerated() where index != hidden {
            guard var frame = frames[line.id] else { continue }
            if let hidden, index > hidden { frame.origin.y -= lift }
            if y < frame.minY { return nil }
            if y < frame.maxY {
                // A whole split dragged from its row can't join another.
                let splits = hidden.map { if case let .row(ids, _, _) = lines[$0].kind { ids.count == 1 } else { true } } ?? true
                return hover(on: index, at: (y - frame.minY) / max(frame.height, 1), dragging: tab, splits: splits)
            }
        }
        // Below everything: the end of the last box.
        return gap(lastBox, at: boxes[lastBox]?.count ?? 0)
    }

    private func hover(on index: Int, at fraction: CGFloat, dragging tab: TabID?, splits: Bool) -> SidebarHover? {
        let line = lines[index]
        switch line.kind {
        case .spaceHeader:
            return nil
        case .pinnedHeader:
            return gap(.pinned, at: 0)
        case .todayHeader, .newTab:
            return gap(.today, at: 0)
        case let .hint(_, target):
            return .onto(line.id, target)
        case let .folder(folder):
            // The lower part of an open folder's line is the top of its list.
            if folder.isOpen, !folder.tabs.isEmpty, fraction > 0.6 { return gap(.folder(folder.id), at: 0) }
            return .onto(line.id, .folder(folder.id, index: .max))
        case let .row(ids, box, row):
            // A row's middle half puts the tab beside it in a split; its edges make room above or
            // below. Wide enough to hold the split preview steady while you look at it.
            if splits, let last = ids.last, ids.count < TabSplit.maxPanes, !ids.contains(where: { $0 == tab }),
               (0.25...0.75).contains(fraction) {
                return .onto(line.id, .split(last, .trailing))
            }
            return gap(box, at: fraction < 0.5 ? row : row + 1)
        }
    }

    private func gap(_ box: Box, at row: Int) -> SidebarHover? {
        guard let rows = boxes[box] else { return nil }
        let target: TabDropTarget = switch box {
        case .pinned: .section(.pinned, row: row)
        case .today: .section(.today, row: row)
        case let .folder(id): .folder(id, index: row)
        }
        return .gap(before: rows.lowerBound + row, box: box, target: target)
    }

    /// The top of a gap opened before the `line`th line, on screen.
    func gapTop(before line: Int, frames: [String: CGRect], hidden: Int?, lift: CGFloat) -> CGFloat {
        let y = line < lines.count ? frames[lines[line].id]?.minY : lines.last.flatMap { frames[$0.id]?.maxY }
        guard let y else { return 0 }
        return hidden.map { line > $0 } == true ? y - lift : y
    }
}

/// Where a tab dragged over the sidebar would land.
enum SidebarHover: Equatable {
    /// Room opens before the `before`th line (or at the end) for the tab to land at `target`.
    case gap(before: Int, box: SidebarLines.Box, target: TabDropTarget)
    /// On a line itself: beside its tab in a split, into a folder, into an empty box.
    case onto(String, TabDropTarget)

    var target: TabDropTarget {
        switch self {
        case let .gap(_, _, target), let .onto(_, target): target
        }
    }
}

/// A drag over the sidebar: where it would land, and the row it came from, which is hidden
/// meanwhile so the rest close up behind it.
@MainActor
@Observable
final class SidebarDropState {
    private(set) var hover: SidebarHover?
    private(set) var hidden: String?
    private(set) var hiddenHeight: CGFloat = 0
    private(set) var gapHeight: CGFloat = 0
    /// Where the pointer is over the list, so the dragged tab can follow it.
    private(set) var pointer: CGPoint?
    /// Every line's frame as laid out, before any gap: what drags are hit-tested against.
    @ObservationIgnored var frames: [String: CGRect] = [:]

    func show(_ hover: SidebarHover?, hiding hidden: String?, height: CGFloat) {
        self.hover = hover
        self.hidden = hidden
        hiddenHeight = hidden == nil ? 0 : height
        gapHeight = height
    }

    func clear() {
        settle(nil)
        hover = nil
        hidden = nil
        hiddenHeight = 0
        pointer = nil
    }

    /// How long the pointer rests on a tab before the row shows the split it would make.
    static let dwell = Duration.milliseconds(450)
    @ObservationIgnored private var settling: SidebarHover?
    @ObservationIgnored private var wait: Task<Void, Never>?

    /// Runs `then` once the pointer has stayed on `hover` for `dwell`; nil gives up waiting.
    func settle(_ hover: SidebarHover?, then: @escaping @MainActor () -> Void = {}) {
        guard hover != settling else { return }
        wait?.cancel()
        settling = hover
        guard hover != nil else { return }
        wait = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard let self, !Task.isCancelled, self.settling == hover else { return }
            self.settling = nil
            then()
        }
    }

    /// The pointer moves on its own, never animated: the dragged tab keeps up with it.
    func follow(_ point: CGPoint) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { pointer = point }
    }

    /// Held over a tab, the row shows the split it would make; the dragged tab steps aside for it.
    var isSplitting: Bool {
        if case .onto(_, .split)? = hover { true } else { false }
    }

    func isTargeting(_ line: String) -> Bool {
        if case let .onto(id, _)? = hover { id == line } else { false }
    }

    /// How far the `index`th line moves: up behind the hidden row, down below an open gap.
    func shift(of index: Int, hidden: Int?) -> CGFloat {
        var dy: CGFloat = 0
        if let hidden, index > hidden { dy -= hiddenHeight }
        if case let .gap(before, _, _)? = hover, index >= before { dy += gapHeight }
        return dy
    }

    /// A gap with no row hidden to make up for it makes the list longer.
    var extraRoom: CGFloat {
        if case .gap? = hover, hidden == nil { gapHeight } else { 0 }
    }
}

/// Takes drags over the whole list: tabs from the sidebar, the page or a favorite, and links
/// from pages and other apps.
struct SidebarDropDelegate: DropDelegate {
    static let types: [UTType] = [.utf8PlainText, .plainText, .url]

    let lines: SidebarLines
    let state: SidebarDropState
    let drag: TabDragSession
    let browser: Browser
    /// A row's height, for a gap with no row of its own to measure.
    let rowHeight: CGFloat

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }

    func dropEntered(info: DropInfo) { follow(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        follow(info)
        return DropProposal(operation: drag.active == nil ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        animate(Motion.travel) { state.clear() }
    }

    func performDrop(info: DropInfo) -> Bool {
        follow(info)
        guard let hover = state.hover else {
            animate(Motion.travel) { state.clear() }
            return false
        }
        if let payload = drag.active {
            if case .gap = hover {
                // The rows already stand where the drop puts them: land without moving anything.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    browser.drop(payload, on: hover.target, animated: false)
                    state.clear()
                }
            } else {
                browser.drop(payload, on: hover.target)
                animate(Motion.travel) { state.clear() }
            }
            return true
        }
        animate(Motion.travel) { state.clear() }
        // A link from a page or another app: open it there.
        let target = hover.target
        let opener = browser
        if let provider = info.itemProviders(for: [.url]).first {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in opener.drop([url.absoluteString], on: target) }
            }
        } else if let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                Task { @MainActor in opener.drop([text], on: target) }
            }
        }
        return true
    }

    private func follow(_ info: DropInfo) {
        let payload = drag.active
        if payload != nil { state.follow(info.location) }
        // A row dragged from the list leaves it; a pane leaving its split doesn't take the row.
        let hidden = payload.flatMap { $0.source == .row ? lines.line(holding: $0.id) : nil }
        let hover = lines.hover(at: info.location.y, frames: state.frames, hidden: hidden, dragging: payload?.id)
        let hiddenID = hidden.map { lines.lines[$0].id }
        guard hover != state.hover || hiddenID != state.hidden else { return state.settle(nil) }
        let height = hiddenID.flatMap { state.frames[$0]?.height } ?? rowHeight
        let show = { [state] in state.show(hover, hiding: hiddenID, height: height) }
        // A split waits until the pointer rests on the tab, so passing over tabs while reordering
        // carries on as a reorder instead of flickering into splits.
        if case .onto(_, .split)? = hover {
            state.settle(hover) { animate(Motion.flow, show) }
        } else {
            state.settle(nil)
            animate(Motion.travel, show)
        }
    }
}

// MARK: - Look

extension EnvironmentValues {
    @Entry var sidebarDensity: Preferences.Density = .comfortable
}

extension Preferences.FavoriteSize {
    var tileHeight: CGFloat {
        switch self {
        case .small: 28
        case .medium: 34
        case .large: 44
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small: 14
        case .medium: 16
        case .large: 22
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .small: 8
        case .medium: 10
        case .large: 13
        }
    }

    /// How narrow and wide a tile gets when the sidebar's width decides how many fit in a row.
    var widths: ClosedRange<CGFloat> {
        switch self {
        case .small: 32...52
        case .medium: 40...64
        case .large: 52...80
        }
    }
}

extension Preferences.Density {
    /// A row's height, without the point of space above and below it.
    var rowHeight: CGFloat {
        switch self {
        case .compact: 26
        case .comfortable: 30
        case .roomy: 34
        }
    }

    var rowFont: Font {
        switch self {
        case .compact: .system(size: 12)
        case .comfortable: .system(size: 13)
        case .roomy: .system(size: 14)
        }
    }
}

extension View {
    /// A sidebar row's look: its height, and a rounded highlight when it's selected, hovered, or
    /// about to take a dropped tab. A row of split panes highlights each pane instead, so it
    /// passes `highlights: false`.
    func sidebarRow(selected: Bool = false, targeted: Bool = false, highlights: Bool = true, indent: CGFloat = 0) -> some View {
        modifier(SidebarRowChrome(selected: selected, targeted: targeted, highlights: highlights, indent: indent))
    }

    /// A section's title line: small and quiet, with room above it.
    func sidebarHeader(top: CGFloat = 10, large: Bool = false) -> some View {
        font(large ? .system(size: 16, weight: .bold, design: .rounded) : .system(size: 11, weight: .semibold))
            .foregroundStyle(large ? .primary : .secondary)
            .padding(.leading, 8)
            .padding(.trailing, 2)
            .frame(maxWidth: .infinity, minHeight: large ? 32 : 24, alignment: .leading)
            .padding(.top, top)
            .padding(.bottom, 2)
    }
}

private struct SidebarRowChrome: ViewModifier {
    let selected: Bool
    let targeted: Bool
    let highlights: Bool
    let indent: CGFloat
    @Environment(\.sidebarDensity) private var density
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        content
            .padding(.leading, 8 + indent)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
            .background {
                shape.fill(fill).overlay { shape.strokeBorder(.tint.opacity(targeted ? 0.9 : 0), lineWidth: 1.5) }
            }
            .animation(Motion.resolved(Motion.feedback), value: hovering)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .padding(.vertical, 1)
    }

    private var fill: AnyShapeStyle {
        if targeted { return AnyShapeStyle(.tint.opacity(0.18)) }
        guard highlights else { return AnyShapeStyle(.clear) }
        let dark = scheme == .dark
        let ink = dark ? Color.white : Color.black
        return AnyShapeStyle(ink.opacity(selected ? (dark ? 0.14 : 0.09) : hovering ? (dark ? 0.06 : 0.045) : 0))
    }
}
