import AppKit
import SkylightBrowser
import SwiftUI

typealias KeyBinding = Preferences.KeyBinding

/// A keyboard shortcut (or a mouse move) and what it does.
struct Shortcut: Identifiable, Equatable {
    let title: String
    let keys: [String]
    /// The menu command it runs, when it's one you can change.
    var command: String?
    /// Whether it's one you set yourself.
    var custom = false
    var id: String { command ?? title + keys.joined() }
}

struct ShortcutGroup: Identifiable, Equatable {
    let title: String
    var items: [Shortcut]
    var id: String { title }
}

/// Your own shortcuts, laid over the menus' own.
@MainActor
public enum ShortcutMap {
    /// Each command's shortcut as the menus set it, before any of yours.
    private static var defaults: [String: KeyBinding] = [:]

    /// Gives every menu command your shortcut for it, or its own.
    public static func apply(_ custom: [String: Preferences.KeyBinding], to menu: NSMenu? = NSApp.mainMenu) {
        let commands = items(in: menu).filter { $0.identifier != nil }
        for item in commands {
            let id = item.identifier!.rawValue
            if defaults[id] == nil { defaults[id] = KeyBinding(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask.rawValue) }
            // Clear them all first: AppKit won't give one item keys another still holds.
            item.keyEquivalent = ""
        }
        for item in commands {
            let id = item.identifier!.rawValue
            guard let binding = custom[id] ?? defaults[id] else { continue }
            item.keyEquivalent = binding.key
            item.keyEquivalentModifierMask = binding.key.isEmpty ? [] : NSEvent.ModifierFlags(rawValue: binding.modifiers)
        }
    }

    static func defaultBinding(_ id: String) -> KeyBinding? { defaults[id] }

    /// Sets `binding` for `command`, taking it off any other command that had it.
    static func set(_ binding: KeyBinding, for command: String, in prefs: Preferences) {
        var custom = prefs.shortcuts
        if !binding.key.isEmpty {
            for item in items(in: NSApp.mainMenu) {
                guard let id = item.identifier?.rawValue, id != command,
                      item.keyEquivalent == binding.key, item.keyEquivalentModifierMask.rawValue == binding.modifiers else { continue }
                custom[id] = defaults[id] == .unassigned ? nil : .unassigned
            }
        }
        custom[command] = defaults[command] == binding ? nil : binding
        prefs.shortcuts = custom
        apply(custom)
    }

    static func reset(_ command: String?, in prefs: Preferences) {
        if let command { prefs.shortcuts[command] = nil } else { prefs.shortcuts = [:] }
        apply(prefs.shortcuts)
    }

    static func items(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { item in [item] + items(in: item.submenu) }
    }
}

enum Shortcuts {
    /// Every command in the menu bar with its shortcut, by menu, so the sheet can't drift from the
    /// menus. Then the moves the menus don't show.
    @MainActor
    static func all(menu: NSMenu? = NSApp.mainMenu, custom: [String: KeyBinding] = [:]) -> [ShortcutGroup] {
        var groups: [ShortcutGroup] = []
        for top in menu?.items ?? [] {
            guard let submenu = top.submenu, submenu !== NSApp.helpMenu else { continue }
            let app = top.title == "Skylight"
            var items = submenu.items.compactMap { item -> Shortcut? in
                // Only Skylight's own commands, named after their action: not what macOS adds to the
                // menus (Dictation, Emoji, the list of windows).
                guard item.submenu == nil, !item.isSeparatorItem, !item.isHidden, let command = item.identifier?.rawValue,
                      command == item.action.map(NSStringFromSelector) || command.hasPrefix("switchToSpace:"),
                      // Commands without a shortcut can take one, except the app menu's.
                      !(app && item.keyEquivalent.isEmpty) else { return nil }
                return Shortcut(title: item.title.replacingOccurrences(of: "…", with: ""),
                                keys: item.keyEquivalent.isEmpty ? [] : keys(item.keyEquivalent, item.keyEquivalentModifierMask),
                                command: command, custom: custom[command] != nil)
            }
            // "Space 1" to "Space 9" read better as one row, while they're still the usual keys.
            let spaces = items.filter { $0.command?.hasPrefix("switchToSpace:") == true }
            if spaces.count > 1, !spaces.contains(where: \.custom), let first = spaces.first, let index = items.firstIndex(of: first) {
                items.removeAll { spaces.contains($0) }
                items.insert(Shortcut(title: "Go to Space 1–9", keys: first.keys.dropLast() + ["1–9"]), at: index)
            }
            if !items.isEmpty { groups.append(ShortcutGroup(title: app ? "App" : top.title, items: items)) }
        }
        groups.append(ShortcutGroup(title: "Address Field", items: [
            Shortcut(title: "Choose a suggestion", keys: ["↑", "↓"]),
            Shortcut(title: "Go", keys: ["↩"]),
            Shortcut(title: "Put the address back", keys: ["esc"]),
        ]))
        groups.append(ShortcutGroup(title: "Mouse", items: [
            Shortcut(title: "Rename a tab", keys: ["Double-click"]),
            Shortcut(title: "More for a tab", keys: ["Right-click"]),
            Shortcut(title: "Split View", keys: ["Drag a tab onto the page"]),
            Shortcut(title: "Resize the sidebar", keys: ["Drag its edge"]),
            Shortcut(title: "Switch Space", keys: ["Swipe two fingers on the sidebar"]),
        ]))
        return groups
    }

    /// The keys to press, as they're printed on the keyboard: modifiers in the Mac's order, then the key.
    static func keys(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> [String] {
        var keys: [String] = []
        if modifiers.contains(.control) { keys.append("⌃") }
        if modifiers.contains(.option) { keys.append("⌥") }
        if modifiers.contains(.shift) || (key.count == 1 && key != key.lowercased()) { keys.append("⇧") }
        if modifiers.contains(.command) { keys.append("⌘") }
        keys.append(named[key] ?? key.uppercased())
        return keys
    }

    private static let named: [String: String] = {
        var names = ["\t": "⇥", "\r": "↩", " ": "Space", "\u{1b}": "esc", "\u{8}": "⌫", "\u{7f}": "⌫"]
        let arrows = [(NSLeftArrowFunctionKey, "←"), (NSRightArrowFunctionKey, "→"), (NSUpArrowFunctionKey, "↑"), (NSDownArrowFunctionKey, "↓")]
        for (code, name) in arrows { names[String(UnicodeScalar(code)!)] = name }
        for n in 1...12 { names[String(UnicodeScalar(NSF1FunctionKey + n - 1)!)] = "F\(n)" }
        return names
    }()

    /// Groups whose name or commands match `query`.
    static func filter(_ groups: [ShortcutGroup], _ query: String) -> [ShortcutGroup] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(query) { return group }
            let items = group.items.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return items.isEmpty ? nil : ShortcutGroup(title: group.title, items: items)
        }
    }
}

/// ⌘/: every shortcut on one sheet, in cards by menu, searchable. Click one to set your own.
struct ShortcutsSheet: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var groups: [ShortcutGroup] = []
    /// The command waiting for its new keys.
    @State private var recording: String?

    var body: some View {
        let shown = Shortcuts.filter(groups, query)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
                    Text("Click a shortcut to change it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(width: 190, height: 26)
                .background(.quinary, in: .rect(cornerRadius: 7))
                if !browser.preferences.shortcuts.isEmpty {
                    Button("Restore Defaults") { change { ShortcutMap.reset(nil, in: browser.preferences) } }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                if shown.isEmpty {
                    Text("No shortcut matches “\(query)”").foregroundStyle(.secondary).padding(.top, 60)
                } else {
                    ShortcutColumns(groups: shown, recording: $recording, set: { binding, command in
                        change { ShortcutMap.set(binding, for: command, in: browser.preferences) }
                    }, reset: { command in
                        change { ShortcutMap.reset(command, in: browser.preferences) }
                    })
                    .padding(20)
                }
            }
        }
        .frame(width: 780, height: 600)
        .onAppear { reload() }
        .onExitCommand { if recording == nil { dismiss() } }
    }

    private func change(_ body: () -> Void) {
        body()
        reload()
    }

    private func reload() { groups = Shortcuts.all(custom: browser.preferences.shortcuts) }
}

/// The cards in two columns, balanced by how many rows each holds.
private struct ShortcutColumns: View {
    let groups: [ShortcutGroup]
    @Binding var recording: String?
    let set: (KeyBinding, String) -> Void
    let reset: (String) -> Void

    var body: some View {
        let (left, right) = Self.balance(groups)
        HStack(alignment: .top, spacing: 14) {
            column(left)
            column(right)
        }
    }

    private func column(_ groups: [ShortcutGroup]) -> some View {
        VStack(spacing: 14) {
            ForEach(groups) { ShortcutCard(group: $0, recording: $recording, set: set, reset: reset) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    static func balance(_ groups: [ShortcutGroup]) -> ([ShortcutGroup], [ShortcutGroup]) {
        var left: [ShortcutGroup] = [], right: [ShortcutGroup] = []
        var leftRows = 0, rightRows = 0
        for group in groups {
            // A card's header and padding count for about two rows.
            let rows = group.items.count + 2
            if leftRows <= rightRows { left.append(group); leftRows += rows } else { right.append(group); rightRows += rows }
        }
        return (left, right)
    }
}

private struct ShortcutCard: View {
    let group: ShortcutGroup
    @Binding var recording: String?
    let set: (KeyBinding, String) -> Void
    let reset: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(group.items) { item in
                HStack(spacing: 8) {
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 8)
                    if let command = item.command {
                        if item.custom {
                            Button { reset(command) } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Back to the usual shortcut")
                        }
                        ShortcutRecorder(keys: item.keys, recording: Binding(get: { recording == command },
                                                                             set: { recording = $0 ? command : nil })) { set($0, command) }
                    } else {
                        Keys(keys: item.keys)
                    }
                }
                .font(.system(size: 12.5))
                .frame(minHeight: 28)
                if item != group.items.last { Divider().opacity(0.5) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary.opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// A command's keys; click to type new ones. Esc cancels, Delete takes the shortcut away.
private struct ShortcutRecorder: View {
    let keys: [String]
    @Binding var recording: Bool
    let record: (KeyBinding) -> Void
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        Button { recording.toggle() } label: {
            Group {
                if recording {
                    Text("Type shortcut…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 21)
                        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1))
                } else if keys.isEmpty {
                    Text(hovering ? "Add" : "—")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 30, minHeight: 21)
                } else {
                    Keys(keys: keys)
                        .padding(2)
                        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 6))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(recording ? "Press the new keys. Esc cancels, Delete removes the shortcut." : "Click to change")
        .onChange(of: recording) { _, now in now ? listen() : stop() }
        .onDisappear { stop() }
    }

    private func listen() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 53 where modifiers.isEmpty:  // esc
                recording = false
            case 51, 117 where modifiers.isEmpty:  // delete, forward delete
                record(.unassigned)
                recording = false
            default:
                let key = event.characters(byApplyingModifiers: [])?.lowercased() ?? ""
                let function = key.unicodeScalars.first.map { $0.value >= 0xF700 && $0.value <= 0xF8FF } ?? false
                // A plain letter would stop you typing it; it needs ⌘, ⌃ or ⌥ (function keys don't).
                guard !key.isEmpty, function || !modifiers.subtracting(.shift).isEmpty else {
                    NSSound.beep()
                    return nil
                }
                record(KeyBinding(key: key, modifiers: modifiers.rawValue))
                recording = false
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct Keys: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(label: $0.element) }
        }
    }
}

/// A key as it looks on the keyboard: a small raised cap.
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: label.count > 2 ? 10.5 : 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, label.count > 1 ? 6 : 0)
            .frame(minWidth: 21, minHeight: 21)
            .background(.background, in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
    }
}

