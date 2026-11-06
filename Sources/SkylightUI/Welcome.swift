import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// Shows the welcome over the window when `Browser` asks for it.
struct WelcomeHost: ViewModifier {
    @Environment(Browser.self) private var browser

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { browser.showsWelcome }, set: { browser.showsWelcome = $0 })) {
                WelcomeSheet()
            }
            .sheet(isPresented: Binding(get: { browser.showHistory }, set: { browser.showHistory = $0 })) {
                HistorySheet()
            }
    }
}

/// What a new install opens with: one question at a time, in a sheet over the window, so a theme
/// picked here shows behind it at once. Every step can be passed over, and Help brings it back.
struct WelcomeSheet: View {
    @Environment(Browser.self) private var browser
    @State private var steps = WelcomeStep.steps(isDefaultBrowser: DefaultBrowser.isSkylight)
    @State private var index = 0
    @State private var forward = true
    @State private var source = Browser.ImportSource.preferred
    @State private var importing = false
    @State private var result: Browser.ImportResult?
    @State private var settingDefault = false

    /// Abstract ones only: the picture themes that show a place wait in Settings.
    private static let looks = ["skylight-default", "sky", "pastel", "vivid", "linen", "sage"]

    private var step: WelcomeStep { steps[index] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .clipped()
            footer
        }
        .frame(width: 580, height: 560)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func page(_ step: WelcomeStep) -> some View {
        switch step {
        case .hello: hello
        case .bringOver: bringOver
        case .look: look
        case .defaultBrowser: defaultBrowser
        case .basics: basics
        }
    }

    // MARK: - Steps

    private var hello: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text("Welcome to Skylight").font(.largeTitle.weight(.semibold))
            Text("A browser that feels like your Mac.")
                .font(.title3).foregroundStyle(.secondary)
        }
        .padding(32)
    }

    private var bringOver: some View {
        VStack(spacing: 18) {
            heading("Bring your browser with you",
                    source == nil ? "Skylight didn't find another browser on this Mac, so you're starting fresh."
                        : "Move in what you have now. Nothing changes in the browser you're leaving.")
            if let result {
                outcome(result)
            } else if let source {
                VStack(spacing: 2) {
                    ForEach(Browser.ImportSource.available, id: \.self) { item in
                        SourceRow(source: item, selected: item == source) { self.source = item }
                    }
                }
                .disabled(importing)
                VStack(alignment: .leading, spacing: 8) {
                    Fact(symbol: "checkmark.circle.fill", tint: .green, text: source.summary)
                    Fact(symbol: "minus.circle", tint: .secondary, text: Browser.ImportSource.staysBehind)
                    Fact(symbol: "lock", tint: .secondary,
                         text: "macOS will ask for your Mac password so Skylight can read \(source.rawValue)'s passwords. They stay on this Mac.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text("Passwords somewhere else, like Safari or your Google Account online? Export them, then bring them in from Settings → Import.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func outcome(_ result: Browser.ImportResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: result.failed ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(result.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                .accessibilityHidden(true)
            Text(result.message)
                .font(.title3)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("\(Browser.ImportSource.staysBehind).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity)
    }

    private var look: some View {
        let prefs = browser.preferences
        let themes = Self.looks.compactMap(prefs.theme)
        let current = prefs.skyBackdrop ? prefs.themeID : nil
        return VStack(spacing: 22) {
            heading("Pick a look", "There are more in Settings, and each Space can have its own.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, selected: theme.id == current, hue: browser.store.state.activeSpace.hue) {
                        animate(Motion.travel) {
                            prefs.skyBackdrop = true
                            prefs.themeID = theme.id
                        }
                    }
                }
            }
        }
        .padding(32)
    }

    private var defaultBrowser: some View {
        VStack(spacing: 14) {
            Image(systemName: "link")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            heading("Open your links here",
                    "Make Skylight your default browser, and links from Mail, Messages and other apps come to it. macOS will check with you first.")
        }
        .padding(32)
    }

    private var basics: some View {
        VStack(spacing: 22) {
            heading("Four things worth knowing", nil)
            VStack(alignment: .leading, spacing: 16) {
                Basic(keys: "⌘T", title: "New tab",
                      detail: "Type a search, an address, an open tab or a command.")
                Basic(keys: "⌥⌘→", title: "Next Space",
                      detail: "Or swipe two fingers sideways over the sidebar.")
                Basic(keys: "⌘S", title: "Show or hide the sidebar",
                      detail: "Your tabs live there: favorites, pinned, then Today.")
                Basic(symbol: "key.fill", title: "Fill a saved password",
                      detail: "Click the key in the address field and pick a login.")
            }
            Text("Every shortcut is in Help → Keyboard Shortcuts.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(32)
    }

    private func heading(_ title: String, _ detail: String?) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title.weight(.semibold))
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Moving on

    private var footer: some View {
        HStack(spacing: 10) {
            if index > 0 {
                Button("Back") { go(-1) }.disabled(importing || settingDefault)
            }
            Spacer()
            Dots(count: steps.count, current: index)
            Spacer()
            switch step {
            case .hello:
                primary("Get Started") { go(1) }
            case .bringOver:
                bringOverButtons
            case .look:
                primary("Continue") { go(1) }
            case .defaultBrowser:
                Button("Not Now") { go(1) }.disabled(settingDefault)
                primary("Make Default") {
                    settingDefault = true
                    Task {
                        await DefaultBrowser.makeSkylight()
                        settingDefault = false
                        go(1)
                    }
                }
                .disabled(settingDefault)
            case .basics:
                primary("Start Browsing") { browser.finishWelcome() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .controlSize(.large)
    }

    @ViewBuilder
    private var bringOverButtons: some View {
        if result != nil {
            Button("Import Another") { result = nil }
            primary("Continue") { go(1) }
        } else if let source {
            Button("Not Now") { go(1) }.disabled(importing)
            primary(importing ? "Importing…" : "Import from \(source.rawValue)") {
                importing = true
                Task {
                    let done = await browser.importBrowser(source, announcing: false)
                    importing = false
                    animate(Motion.arrive) { result = done }
                }
            }
            .disabled(importing)
        } else {
            primary("Continue") { go(1) }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    private func go(_ offset: Int) {
        forward = offset > 0
        animate(Motion.arrive) { index += offset }
    }
}

/// A browser to import from, with its own icon.
private struct SourceRow: View {
    let source: Browser.ImportSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: source.icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text(source.rawValue)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct Fact: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

/// A key or a symbol, and what it does.
private struct Basic: View {
    var keys: String?
    var symbol: String?
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let keys {
                    Text(keys).font(.system(.body, design: .rounded).weight(.medium))
                } else if let symbol {
                    Image(systemName: symbol)
                }
            }
            .frame(width: 58, height: 34)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .accessibilityHidden(keys == nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Dots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { i in
                Circle()
                    .fill(i == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

extension Browser.ImportSource {
    /// The browser's own icon, or a generic app's if it's gone.
    fileprivate var icon: NSImage {
        let workspace = NSWorkspace.shared
        let app = (chromium?.bundleIDs ?? []).lazy.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
        return app.map { workspace.icon(forFile: $0.path) } ?? workspace.icon(for: .application)
    }
}
