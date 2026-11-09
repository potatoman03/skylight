import AppKit
import SkylightBrowser
import SkylightCore
import SwiftUI

/// Shows the welcome over the window when `Browser` asks for it, and the sheets that go with it.
struct WelcomeHost: ViewModifier {
    @Environment(Browser.self) private var browser

    func body(content: Content) -> some View {
        content
            .overlay {
                if browser.showsWelcome {
                    WelcomeCanvas()
                        .ignoresSafeArea()
                        // It opens on night at once, and leaves as a dissolve.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.5))))
                }
            }
            .sheet(isPresented: Binding(get: { browser.showHistory }, set: { browser.showHistory = $0 })) {
                HistorySheet()
            }
            .sheet(item: Binding(get: { browser.importReport }, set: { browser.importReport = $0 })) { report in
                ImportReportSheet(report: report)
            }
    }
}

/// What a new install opens with, over the whole window and the theme behind it. Night, then a
/// light where the theme's ribbons cross, the theme opening out of it, and the name. Then a
/// question at a time, in the calm left side of the picture. A theme picked here changes behind
/// it at once, and at the end the canvas dissolves into the same backdrop, so there's no seam.
struct WelcomeCanvas: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @State private var steps = WelcomeStep.steps(isDefaultBrowser: DefaultBrowser.isSkylight)
    @State private var index = 0
    @State private var openedAt = Date.now
    @State private var opened = false
    /// The opening's ribbons are at rest.
    @State private var settled = false
    @State private var leaving = false
    @State private var source = Browser.ImportSource.preferred
    /// The browsers here, looked up once: finding them asks Launch Services.
    @State private var sources = Browser.ImportSource.available
    @State private var importing = false
    @State private var result: ImportReport?
    @State private var imported: Set<Browser.ImportSource> = []
    @State private var settingDefault = false

    /// The picture themes; the patterns and skies wait in Settings.
    private static let looks = SkyTheme.pictureThemes.map(\.id)

    private var step: WelcomeStep { steps[index] }
    private var screens: [WelcomeStep] { steps.filter { $0 != .hello } }

    /// The other browsers on this Mac that nothing's come from yet.
    private var stillToImport: [Browser.ImportSource] {
        sources.filter { !imported.contains($0) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // The theme's picture, its ribbons flowing in with the opening and still by the
                // first question. Then it goes, and the backdrop under it carries on unchanged.
                if let flowing, !settled {
                    FlowingPicture(url: flowing.url, image: flowing.image, dark: scheme == .dark, start: openedAt,
                                   stillBy: Opening.namesLeave, calm: opened)
                }
                // Keeps the words readable over any theme, without hiding it.
                Scrim(dark: scheme == .dark)
                    .opacity(opened && !leaving ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8), value: opened)
                    .animation(.easeInOut(duration: 0.5), value: leaving)
                if opened {
                    screen(in: geo.size)
                }
                if !opened {
                    Opening(start: openedAt, glow: glowPoint(in: geo.size), veil: veilColors) { finishOpening() }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The theme's own accent, as the window has it.
        .tint(accentColor)
        .onAppear {
            openedAt = .now
            if step != .hello { opened = true; settled = true } else { OpeningSound.shared.play() }
            // While it's still night, so the first question doesn't wait on them.
            for source in sources { _ = source.icon }
        }
    }

    // MARK: - The opening

    private var accentColor: Color {
        let prefs = browser.preferences
        let space = browser.store.state.activeSpace
        return Color(prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue).accent)
    }

    /// The theme's picture, if it can flow: not with Reduce Motion, and not a GIF or a blurred one.
    private var flowing: (url: URL, image: ThemeImage)? {
        let prefs = browser.preferences
        let space = browser.store.state.activeSpace
        guard !Motion.reduceMotion, prefs.showsTheme(in: space),
              let image = prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue).image,
              FlowingPicture.shows(image), let url = prefs.url(for: image) else { return nil }
        return (url, image)
    }

    /// The theme's own sky, darkest where the night is.
    private var veilColors: [Color] {
        let prefs = browser.preferences
        let space = browser.store.state.activeSpace
        let palette = prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue)
        return [Color(palette.sky), Color(palette.horizon)]
    }

    /// Where the light comes from: where Skylight Default's ribbons cross, wherever the picture
    /// sits in the window. Other themes light up a little right of center.
    private func glowPoint(in size: CGSize) -> CGPoint {
        let prefs = browser.preferences
        guard prefs.theme(for: browser.store.state.activeSpace).id == SkyTheme.startingID else {
            return CGPoint(x: size.width * 0.62, y: size.height * 0.56)
        }
        // The picture fills the window, cropped at the edges, and the crossing is at (0.61, 0.55).
        let picture = CGSize(width: 1586, height: 992)
        let scale = max(size.width / picture.width, size.height / picture.height)
        let shown = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGPoint(x: (size.width - shown.width) / 2 + shown.width * 0.61,
                       y: (size.height - shown.height) / 2 + shown.height * 0.55)
    }

    private func finishOpening() {
        guard !opened else { return }
        withAnimation(.easeOut(duration: 0.2)) { opened = true }
        // Already still, unless the opening was skipped; then they settle first.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            settled = true
        }
        index = min(index + 1, steps.count - 1)
    }

    // MARK: - The questions

    @ViewBuilder
    private func screen(in size: CGSize) -> some View {
        let margin = max(56, size.width * 0.075)
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 64)
            ZStack(alignment: .leading) {
                page(step)
                    .id(step)
                    .transition(.asymmetric(insertion: .identity, removal: Drift.leaving))
            }
            .frame(width: min(460, size.width - margin * 2), alignment: .leading)
            .opacity(leaving ? 0 : 1)
            .blur(radius: leaving && !Motion.reduceMotion ? 6 : 0)
            .animation(.easeIn(duration: 0.35), value: leaving)
            Spacer(minLength: 40)
            Progress(count: screens.count, current: screens.firstIndex(of: step) ?? 0)
                .opacity(leaving ? 0 : 1)
                .animation(.easeIn(duration: 0.3), value: leaving)
                .padding(.bottom, 36)
        }
        .padding(.leading, margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func page(_ step: WelcomeStep) -> some View {
        switch step {
        case .hello: EmptyView()
        case .bringOver: bringOver
        case .look: look
        case .defaultBrowser: defaultBrowser
        case .basics: basics
        }
    }

    private var bringOver: some View {
        Screen {
            if let result {
                Rise(0) { Title(result.headline) }
                Rise(1) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ImportChecklist(report: result)
                            if let next = stillToImport.first {
                                ImportLine(line: .init(kind: .needsYou, title: "\(next.rawValue) is on this Mac too",
                                                       detail: "Bring it over as well with Import from \(next.rawValue)"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.never)
                    .frame(maxHeight: 300)
                }
                Rise(2) {
                    Buttons {
                        Primary("Continue") { go(1) }
                        if let next = stillToImport.first {
                            Secondary("Import from \(next.rawValue)") {
                                animate(Motion.arrive) {
                                    source = next
                                    self.result = nil
                                }
                            }
                        }
                    }
                }
            } else if let source {
                Rise(0) { Title("Bring your things with you") }
                Rise(1) { Lede("Tabs, passwords, sign-ins and extensions come over. Nothing changes in the browser you're leaving.") }
                Rise(2) {
                    HStack(spacing: 10) {
                        ForEach(sources, id: \.self) { item in
                            SourceTile(source: item, selected: item == source) {
                                animate(Motion.travel) { self.source = item }
                            }
                        }
                    }
                    .disabled(importing)
                }
                Rise(3) {
                    VStack(alignment: .leading, spacing: 10) {
                        Note(symbol: "arrow.down.circle", text: "From \(source.rawValue): \(source.summary).")
                        Note(symbol: "lock", text: "Next, macOS asks for your Mac password, so Skylight can read the passwords \(source.rawValue) saved. They stay on this Mac.")
                    }
                }
                Rise(4) {
                    if importing {
                        Working(step: browser.importStep ?? "Getting ready…")
                    } else {
                        Buttons {
                            Primary("Import from \(source.rawValue)") { startImport(source) }
                            Secondary("Not Now") { go(1) }
                        }
                    }
                }
                Rise(5) {
                    Text("Passwords somewhere else, like Safari or your Google Account? Export them, then bring them in from Settings → Import.")
                        .font(.footnote).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Rise(0) { Title("A fresh start") }
                Rise(1) { Lede("Skylight didn't find another browser on this Mac, so there's nothing to bring over. Passwords you've exported can come in from Settings → Import.") }
                Rise(2) { Buttons { Primary("Continue") { go(1) } } }
            }
        }
    }

    private func startImport(_ source: Browser.ImportSource) {
        animate(Motion.travel) { importing = true }
        Task {
            let done = await browser.importBrowser(source, announcing: false)
            imported.insert(source)
            animate(Motion.arrive) {
                importing = false
                result = done
            }
        }
    }

    private var look: some View {
        let prefs = browser.preferences
        let themes = Self.looks.compactMap(prefs.theme)
        let current = prefs.skyBackdrop ? prefs.themeID : nil
        return Screen {
            Rise(0) { Title("Pick a look") }
            Rise(1) { Lede("It changes behind you as you choose. There are more in Settings, and each Space can have its own.") }
            Rise(2) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                    ForEach(themes) { theme in
                        ThemeCard(theme: theme, selected: theme.id == current, hue: browser.store.state.activeSpace.hue) {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                prefs.skyBackdrop = true
                                prefs.themeID = theme.id
                            }
                        }
                    }
                }
            }
            Rise(3) { Buttons { Primary("Continue") { go(1) } } }
        }
    }

    private var defaultBrowser: some View {
        Screen {
            Rise(0) { Title("Open your links here") }
            Rise(1) { Lede("Make Skylight your default browser, and links from Mail, Messages and your other apps open here. macOS checks with you first.") }
            Rise(2) {
                Buttons {
                    Primary("Make Default") {
                        settingDefault = true
                        Task {
                            await DefaultBrowser.makeSkylight()
                            settingDefault = false
                            go(1)
                        }
                    }
                    .disabled(settingDefault)
                    Secondary("Not Now") { go(1) }.disabled(settingDefault)
                }
            }
        }
    }

    private var basics: some View {
        Screen {
            Rise(0) { Title("Make yourself at home") }
            Rise(1) {
                VStack(alignment: .leading, spacing: 14) {
                    Basic(keys: "⌘T", title: "New tab", detail: "Type a search, an address, an open tab or a command.")
                    Basic(keys: "⌘S", title: "Show or hide the sidebar", detail: "Your tabs live there: favorites, pinned, then Today.")
                    Basic(keys: "⌥⌘→", title: "Next Space", detail: "Or swipe sideways with two fingers over the sidebar.")
                }
            }
            Rise(2) { Buttons { Primary("Start Browsing") { leave() } } }
        }
    }

    private func go(_ offset: Int) {
        let next = index + offset
        guard steps.indices.contains(next), steps[next] != .hello else { return leave() }
        withAnimation(.easeIn(duration: 0.25)) { index = next }
    }

    /// The words go first; then the window's own sidebar and toolbar come up over the same backdrop.
    private func leave() {
        guard !leaving else { return }
        leaving = true
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            browser.finishWelcome()
        }
    }
}

// MARK: - The opening

/// Night over the theme, a light rising where its ribbons cross, the theme opening out of the
/// light, and the name arriving with the chime. A click, Return or Escape moves on.
private struct Opening: View {
    let start: Date
    let glow: CGPoint
    let veil: [Color]
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var skippedAt: Double?

    /// When the words have gone and the first question can come.
    private static let length = 4.7
    /// When the name has gone; the ribbons are still by then.
    static let namesLeave = 4.6

    var body: some View {
        TimelineView(.animation) { context in
            let t = time(at: context.date)
            GeometryReader { geo in
                ZStack {
                    night(t, size: geo.size)
                    light(t)
                    name(t)
                }
            }
            .onChange(of: t >= Self.length) { _, over in if over { done() } }
        }
        .contentShape(.rect)
        .onTapGesture { skip() }
        .background {
            // Return or Escape: invisible, so they work without focus.
            Button("Skip") { skip() }.keyboardShortcut(.defaultAction).opacity(0)
            Button("Skip") { skip() }.keyboardShortcut(.cancelAction).opacity(0)
        }
        .accessibilityElement()
        .accessibilityLabel("Welcome to Skylight")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { skip() }
    }

    /// Seconds into the opening. Skipping runs the rest quickly instead of cutting it.
    private func time(at date: Date) -> Double {
        let t = date.timeIntervalSince(start)
        if Motion.reduceMotion { return reduced(t) }
        guard let skippedAt else { return t }
        let from = max(skippedAt, 3.6)
        return min(Self.length, from + (t - skippedAt) * 3)
    }

    /// With Reduce Motion: the night fades, the name fades in and out. Nothing moves or grows.
    private func reduced(_ t: Double) -> Double {
        guard let skippedAt else { return t }
        return max(t, skippedAt + (Self.length - skippedAt))
    }

    private func skip() {
        guard skippedAt == nil else { return }
        skippedAt = Date.now.timeIntervalSince(start)
        OpeningSound.shared.fadeOut()
    }

    // The theme opens out of the light: the night has a hole, soft-edged, that grows from the
    // light until it's past every corner.
    private func night(_ t: Double, size: CGSize) -> some View {
        let reach = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map { hypot($0.x - glow.x, $0.y - glow.y) }.max() ?? 1
        let opening = Motion.reduceMotion ? 0 : ease((t - 1.0) / 2.1)
        let radius = max(1, opening * reach * 1.9)
        let gone = Motion.reduceMotion ? ease((t - 0.6) / 1.4) : ease((t - 3.0) / 0.6)
        return LinearGradient(colors: veil, startPoint: .top, endPoint: .bottom)
            .mask {
                RadialGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.42),
                                       .init(color: .black, location: 1)],
                               center: UnitPoint(x: glow.x / size.width, y: glow.y / size.height),
                               startRadius: 0, endRadius: radius)
            }
            .opacity(1 - gone)
    }

    // A warm point that swells, lights the opening, and leaves the theme's own glow in its place.
    @ViewBuilder
    private func light(_ t: Double) -> some View {
        if !Motion.reduceMotion {
            let rise = ease((t - 0.25) / 1.1)
            let fade = 1 - ease((t - 2.2) / 1.6)
            let size = 40 + 440 * ease((t - 0.3) / 2.6)
            let dark = scheme == .dark
            RadialGradient(colors: [.white.opacity(0.66), Color(red: 1, green: 0.72, blue: 0.55).opacity(0.52),
                                    Color(red: 1, green: 0.45, blue: 0.68).opacity(0.22), .clear],
                           center: .center, startRadius: 0, endRadius: size / 2)
                .frame(width: size, height: size)
                .position(glow)
                .opacity(rise * fade * (dark ? 0.72 : 0.6))
                .blendMode(dark ? .plusLighter : .normal)
                .allowsHitTesting(false)
        }
    }

    // The name, in New York, drawing together as it sharpens; then up and away.
    private func name(_ t: Double) -> some View {
        let chime = OpeningSound.chime
        let still = Motion.reduceMotion
        let come = ease((t - (chime - 0.25)) / 1.1)
        let line = ease((t - (chime + 0.45)) / 0.9)
        let go = ease((t - 3.95) / (Self.namesLeave - 3.95))
        return VStack(spacing: 12) {
            Text("Skylight")
                .font(.system(size: 64, weight: .regular, design: .serif))
                .tracking(still ? 1 : 1 + 12 * (1 - come))
                .blur(radius: still ? 0 : 12 * (1 - come))
                .opacity(come)
            Text("A browser that feels like your Mac.")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .opacity(line)
                .offset(y: still ? 0 : 6 * (1 - line))
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color(red: 0.08, green: 0.1, blue: 0.17))
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0), radius: 18)
        .offset(y: still ? 0 : -14 * go)
        .blur(radius: still ? 0 : 5 * go)
        .opacity(1 - go)
        .allowsHitTesting(false)
    }

    /// Slow out of the start, a long settle: the light shouldn't snap.
    private func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 1 - pow(1 - t, 3) * (1 - t * 0.35)
    }
}

// MARK: - Pieces

/// A soft wash behind the words on the left, in the theme's own darkness or light.
private struct Scrim: View {
    let dark: Bool

    var body: some View {
        let tone = dark ? Color(red: 0.02, green: 0.025, blue: 0.08) : Color(red: 0.96, green: 0.97, blue: 1)
        LinearGradient(stops: [.init(color: tone.opacity(dark ? 0.55 : 0.6), location: 0), .init(color: tone.opacity(dark ? 0.3 : 0.35), location: 0.38),
                               .init(color: tone.opacity(0), location: 0.7)],
                       startPoint: .leading, endPoint: .trailing)
            .allowsHitTesting(false)
    }
}

/// A screen's column. Each part rises into place a moment after the one before.
private struct Screen<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) { content }
            .environment(\.welcomeShown, shown)
            .onAppear { shown = true }
    }
}

private extension EnvironmentValues {
    @Entry var welcomeShown = false
}

/// One part of a screen, arriving `order` beats after the screen does.
private struct Rise<Content: View>: View {
    let order: Int
    @ViewBuilder let content: Content
    @Environment(\.welcomeShown) private var shown

    init(_ order: Int, @ViewBuilder content: () -> Content) {
        self.order = order
        self.content = content()
    }

    var body: some View {
        let still = Motion.reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || still ? 0 : 14)
            .blur(radius: shown || still ? 0 : 8)
            // After the screen before has gone, so the two never blur into each other.
            .animation(.smooth(duration: still ? 0.3 : 0.7).delay(0.24 + Double(order) * 0.07), value: shown)
    }
}

/// How a screen leaves: up a little, softening as it goes.
private struct Drift: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: offset).blur(radius: blur).opacity(opacity)
    }

    static var leaving: AnyTransition {
        let still = Motion.reduceMotion
        return .modifier(active: Drift(offset: still ? 0 : -10, blur: still ? 0 : 6, opacity: 0),
                         identity: Drift(offset: 0, blur: 0, opacity: 1))
            .animation(.easeIn(duration: 0.2))
    }
}

private struct Title: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 40, weight: .regular, design: .serif))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Lede: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 17))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Note: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
    }
}

private struct Buttons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .controlSize(.extraLarge)
            .padding(.top, 6)
    }
}

private struct Primary: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 5) }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
    }
}

private struct Secondary: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 15, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 5) }
            .buttonStyle(.glass)
    }
}

/// While an import runs: what it's doing, on a line that glows along.
private struct Working: View {
    let step: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step)
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: step)
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                GeometryReader { geo in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(LinearGradient(colors: [.clear, .accentColor, .clear], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * 0.35)
                                .offset(x: Motion.reduceMotion ? geo.size.width * 0.32 : geo.size.width * (phase * 1.35 - 0.35))
                        }
                        .clipShape(.capsule)
                }
            }
            .frame(width: 280, height: 3)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

/// A browser to import from: its icon, large, with its name under it.
private struct SourceTile: View {
    let source: Browser.ImportSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: source.icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .accessibilityHidden(true)
                Text(source.rawValue)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: 92, height: 96)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.clear)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                }
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Where you are: a short line for each question, the current one long and bright.
private struct Progress: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: i == current ? 22 : 6, height: 4)
            }
        }
        .animation(.smooth(duration: 0.5), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// What an import did: what came over, what needs you, and what was left.
struct ImportChecklist: View {
    let report: ImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(report.lines) { ImportLine(line: $0) }
        }
    }
}

struct ImportLine: View {
    let line: ImportReport.Line

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .foregroundStyle(line.kind == .skipped ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            switch line.kind {
            case .added: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsYou: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .textSelection(.enabled)
    }
}

/// The result of an import started from the menu or Settings.
struct ImportReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: ImportReport

    var body: some View {
        VStack(spacing: 18) {
            Text(report.headline).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            ScrollView {
                ImportChecklist(report: report).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 460)
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


@MainActor
private var sourceIcons: [Browser.ImportSource: NSImage] = [:]

extension Browser.ImportSource {
    /// The browser's own icon, or a tile with its initial when the app is gone (its data can
    /// outlive it, and macOS draws a generic app as a blank page). Kept, because finding it asks
    /// Launch Services and reads the app's icon file.
    @MainActor
    fileprivate var icon: NSImage {
        if let icon = sourceIcons[self] { return icon }
        let icon = Self.appIcon(chromium?.bundleIDs ?? []) ?? Self.tile(rawValue)
        sourceIcons[self] = icon
        return icon
    }

    /// Reads the icon from the app itself first: for some apps, Arc among them, `icon(forFile:)`
    /// returns a folder's icon.
    @MainActor
    private static func appIcon(_ bundleIDs: [String]) -> NSImage? {
        let workspace = NSWorkspace.shared
        guard let url = bundleIDs.lazy.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first else { return nil }
        if let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
               let path = bundle.path(forResource: name.hasSuffix(".icns") ? name : name + ".icns", ofType: nil),
               let image = NSImage(contentsOfFile: path) {
                return image
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
               let image = bundle.image(forResource: name) {
                return image
            }
        }
        return workspace.icon(forFile: url.path)
    }

    /// A light tile on the app icon grid with the browser's initial, drawn at whatever size it's shown.
    private static func tile(_ name: String) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let inset = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
            let shape = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225)
            NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.86, alpha: 1))?.draw(in: shape, angle: -90)
            NSColor(white: 0, alpha: 0.08).setStroke()
            shape.lineWidth = rect.width / 128
            shape.stroke()
            let base = NSFont.systemFont(ofSize: inset.height * 0.5, weight: .semibold)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
            let letter = NSAttributedString(string: String(name.prefix(1)), attributes: [.font: font, .foregroundColor: NSColor(white: 0.32, alpha: 1)])
            let size = letter.size()
            letter.draw(at: NSPoint(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2))
            return true
        }
    }
}
