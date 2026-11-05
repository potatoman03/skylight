import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// A Space's look, chosen in one place: its icon, color, sidebar tint and sky. Everything applies as
/// you pick it, so the sidebar behind the popover is the preview.
struct SpaceCustomizer: View {
    let space: Space
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @State private var page = Page.symbols
    @State private var typed = ""
    @FocusState private var typing: Bool

    private enum Page: String, CaseIterable, Identifiable {
        case symbols = "Symbols", emoji = "Emoji"
        var id: String { rawValue }
    }

    private static let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    static let symbols: [String] = SpaceMenu.icons.map(\.symbol) + [
        "sparkles", "cloud", "mountain.2", "tree", "pawprint", "airplane", "car", "bicycle",
        "camera", "film", "headphones", "gamecontroller", "dumbbell", "fork.knife", "cup.and.saucer",
        "building.2", "banknote", "chart.bar", "hammer", "terminal", "flask", "lightbulb", "calendar",
    ]

    static let emoji = [
        "😀", "😎", "🤓", "🧠", "💼", "🏠", "📚", "🎓",
        "🎨", "🎵", "🎮", "🎬", "✈️", "🏝️", "🏔️", "🌿",
        "🌸", "🔥", "⚡️", "⭐️", "🌙", "☀️", "❤️", "🚀",
        "🧪", "💡", "💰", "📈", "🛒", "🍕", "☕️", "🐾",
    ]

    var body: some View {
        let store = browser.store
        @Bindable var prefs = browser.preferences
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Icon", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch page {
                case .symbols: symbolGrid
                case .emoji: emojiGrid
                }
            }
            section("Color") {
                HStack(spacing: 0) {
                    ForEach(SpaceMenu.colors, id: \.name) { color in
                        ColorDot(hue: color.hue, selected: SpaceMenu.matches(space.hue, color.hue)) {
                            store.send(.setSpaceHue(space.id, color.hue))
                        }
                        .help(color.name)
                        .frame(maxWidth: .infinity)
                    }
                }
                HueStrip(hue: Binding(get: { space.hue }, set: { store.send(.setSpaceHue(space.id, $0)) }))
            }
            section("Sidebar tint") {
                Picker("Sidebar tint", selection: Binding(get: { space.tint }, set: { store.send(.setSpaceTint(space.id, $0)) })) {
                    ForEach(SpaceTint.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            section("Sky") {
                Picker("Sky", selection: Binding(get: { space.themeID }, set: { store.send(.setSpaceTheme(space.id, $0)) })) {
                    Text("Same as the app").tag(String?.none)
                    Divider()
                    ForEach(prefs.themes) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                Toggle("Show the sky behind the sidebar", isOn: $prefs.skyBackdrop)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 292)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Self.columns, spacing: 4) {
            IconCell(selected: space.icon == nil, help: "First letter") { browser.store.send(.setSpaceIcon(space.id, nil)) } label: {
                SpaceIcon(icon: nil, name: space.name, size: 14)
            }
            ForEach(Self.symbols, id: \.self) { symbol in
                IconCell(selected: space.icon == symbol, help: symbol) { browser.store.send(.setSpaceIcon(space.id, symbol)) } label: {
                    SpaceIcon(icon: symbol, name: space.name, size: 14)
                }
            }
        }
    }

    private var emojiGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(Self.emoji, id: \.self) { emoji in
                    IconCell(selected: space.icon == emoji, help: emoji) { browser.store.send(.setSpaceIcon(space.id, emoji)) } label: {
                        Text(emoji).font(.system(size: 15))
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Any emoji", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onChange(of: typed) { _, text in take(text) }
                Button {
                    // The palette types into whatever has focus, so the field has to have it first.
                    typing = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                } label: {
                    Image(systemName: "face.smiling")
                }
                .help("Emoji & Symbols")
            }
        }
    }

    /// Keeps the last emoji typed or picked, and nothing else: the icon is one character.
    private func take(_ text: String) {
        guard !text.isEmpty else { return }
        guard let emoji = text.last(where: \.isEmoji) else {
            typed = ""
            return
        }
        if typed != String(emoji) { typed = String(emoji) }
        browser.store.send(.setSpaceIcon(space.id, String(emoji)))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }
}

private extension Character {
    /// ASCII digits and "#" count as emoji to Unicode, but nobody means them as one.
    var isEmoji: Bool { unicodeScalars.contains { $0.properties.isEmoji && !$0.isASCII } }
}

/// One choice in the icon grid.
private struct IconCell<Label: View>: View {
    let selected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            label()
                .frame(width: 28, height: 28)
                .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                     : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0)), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { h in animate(Motion.feedback) { hovering = h } }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A preset color, ringed when it's the Space's.
private struct ColorDot: View {
    let hue: Double
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Theme.accent(hue, scheme))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Any hue: the color wheel laid out flat, with a knob to drag.
private struct HueStrip: View {
    @Binding var hue: Double
    @Environment(\.colorScheme) private var scheme

    private static let knob: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.knob, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 1, by: 1 / 12).map { Theme.accent($0, scheme) },
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: hue * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                hue = min(max((value.location.x - Self.knob / 2) / travel, 0), 0.999)
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Custom color")
        .accessibilityValue("\(Int((hue * 360).rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.02 : -0.02
            hue = min(max(hue + step, 0), 0.999)
        }
    }
}
