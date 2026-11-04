import AppKit
import SkylightBrowser
import SkylightCore
import SkylightEngine
import SwiftUI

/// The page card: the engine's view, rounded and floating on the backdrop, with the progress
/// line, prompts and the empty state on top.
struct ContentArea: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var palette

    var body: some View {
        let tab = browser.store.state.selectedTab
        let status = browser.selectedStatus
        let prompt = browser.prompts.prompt(for: browser.pages.visibleTabID)
        let offer = browser.passwords.offer

        ZStack(alignment: .top) {
            PageHost(view: browser.pages.hostView, radius: radius)
            if tab == nil {
                StartView().transition(.opacity)
            } else if let tab, tab.url.isSkylightPage {
                SettingsPage(url: tab.url).transition(.opacity)
            }
            ProgressLine(progress: status.progress, loading: status.isLoading)
            if let prompt {
                PromptCard(prompt: prompt)
                    .id(prompt.id)
                    .padding(.top, 14)
                    .transition(Arrive(anchor: .top, scale: 0.96, rise: -8))
            } else if let offer, offer.tabID == browser.pages.visibleTabID {
                PasswordOfferCard(offer: offer)
                    .id(offer.id)
                    .padding(.top, 14)
                    .transition(Arrive(anchor: .top, scale: 0.96, rise: -8))
            }
        }
        .motion(Motion.arrive, value: prompt?.id)
        .motion(Motion.arrive, value: offer?.id)
        .motion(Motion.swap, value: tab == nil)
        // An empty tab has no card: the field floats on the sky.
        .background(tab == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.background))
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Surface.selected.edge(scheme), lineWidth: 0.75)
                .opacity(tab == nil ? 0 : 1)
        }
        .shadow(color: Theme.shadow(palette, scheme).opacity(tab == nil ? 0 : 1), radius: 18, y: 6)
    }

    private var radius: CGFloat { browser.preferences.cornerRadius }
}

/// Hosts the coordinator's page container. SwiftUI never re-creates it, so pages keep running.
struct PageHost: NSViewRepresentable {
    let view: PageHostView
    var radius = Theme.cardRadius

    func makeNSView(context: Context) -> PageHostView {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: PageHostView, context: Context) {
        if view.layer?.cornerRadius != radius { view.layer?.cornerRadius = radius }
    }
}

private struct ProgressLine: View {
    let progress: Double
    let loading: Bool

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.tint)
                .frame(width: max(0, geo.size.width * (loading ? max(progress, 0.08) : 1)), height: 2.5)
                .opacity(loading ? 1 : 0)
                .motion(Motion.travel, value: progress)
                .motion(Motion.exit, value: loading)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

/// An empty tab: one field in the middle of the sky, where the command bar opens.
private struct StartView: View {
    @Environment(Browser.self) private var browser
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                    Text("Search or enter address").font(.system(size: 18))
                    Spacer()
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .frame(width: CommandBarLayout.width(in: geo.size.width), height: CommandBarLayout.fieldHeight)
                .surface(hovering ? .selected : .field, radius: 22)
                .contentShape(.rect)
                .onTapGesture { browser.presentCommandBar(.newTab) }
                .onHover { h in animate(Motion.feedback) { hovering = h } }

                Text("⌘T new tab   ·   ⌘L address   ·   ⌘S sidebar   ·   ⌘, settings")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, CommandBarLayout.top(in: geo.size.height, empty: true))
            .opacity(browser.commandBar.isPresented ? 0 : 1)
        }
    }
}

// MARK: - Prompts

private struct PromptCard: View {
    let prompt: Prompt
    @Environment(Browser.self) private var browser
    @State private var text = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch prompt {
            case let .permission(_, request):
                header(symbol: Self.symbol(request.kinds), title: "\(Self.host(request.origin)) wants to \(Self.describe(request.kinds))")
                Toggle("Remember for this site", isOn: $remember).toggleStyle(.checkbox).font(.system(size: 12))
                buttons(cancel: "Don't Allow", ok: "Allow",
                        onCancel: { browser.prompts.answer(permission: request, allow: false, remember: remember) },
                        onOK: { browser.prompts.answer(permission: request, allow: true, remember: remember) })

            case let .dialog(_, request):
                header(symbol: request.kind == .alert ? "exclamationmark.bubble" : "questionmark.bubble",
                       title: "\(Self.host(request.origin)) says")
                Text(request.message).font(.system(size: 13)).textSelection(.enabled).lineLimit(12)
                if request.kind == .prompt {
                    TextField("", text: $text).textFieldStyle(.roundedBorder)
                        .onAppear { text = request.defaultText }
                        .onSubmit { browser.prompts.answer(dialog: request, ok: true, text: text) }
                }
                buttons(cancel: request.kind == .alert ? nil : "Cancel", ok: "OK",
                        onCancel: { browser.prompts.answer(dialog: request, ok: false) },
                        onOK: { browser.prompts.answer(dialog: request, ok: true, text: text) })

            case let .approval(approval):
                header(symbol: "sparkles", title: "\(approval.client) wants to act in Skylight")
                Text(approval.summary).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(4)
                HStack {
                    Button("Allow for This Session") { browser.prompts.answer(approval: approval, allow: true, trustClient: true) }
                        .buttonStyle(.glass)
                    Spacer()
                    Button("Deny") { browser.prompts.answer(approval: approval, allow: false) }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button("Allow") { browser.prompts.answer(approval: approval, allow: true) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
    }

    private func header(symbol: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.tint)
            Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
        }
    }

    private func buttons(cancel: String?, ok: String, onCancel: @escaping () -> Void, onOK: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            if let cancel {
                Button(cancel, action: onCancel).buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            Button(ok, action: onOK).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
        }
    }

    static func host(_ origin: String) -> String {
        URL(string: origin)?.host(percentEncoded: false) ?? (origin.isEmpty ? "This page" : origin)
    }

    static func describe(_ kinds: [PermissionRequest.Kind]) -> String {
        let phrases = kinds.map { kind -> String in
            switch kind {
            case .camera: "use your camera"
            case .microphone: "use your microphone"
            case .screen: "share your screen"
            case .geolocation: "know your location"
            case .notifications: "show notifications"
            case .clipboard: "see what you copy"
            case .midi: "use MIDI devices"
            case .fileSystem: "edit files"
            case .storageAccess: "use cookies on other sites"
            case .windowManagement: "manage windows"
            case .localFonts: "use your fonts"
            case .idleDetection: "know when you're idle"
            case .keyboardLock: "capture your keyboard"
            case .pointerLock: "lock your pointer"
            case .protocolHandler: "open links of a type"
            case .multipleDownloads: "download several files"
            case .other: "use a device feature"
            }
        }
        return ListFormatter.localizedString(byJoining: phrases)
    }

    static func symbol(_ kinds: [PermissionRequest.Kind]) -> String {
        switch kinds.first {
        case .camera: "video"
        case .microphone: "mic"
        case .screen: "rectangle.on.rectangle"
        case .geolocation: "location"
        case .notifications: "bell"
        case .clipboard: "doc.on.clipboard"
        default: "hand.raised"
        }
    }
}

// MARK: - Toasts

struct ToastView: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        ZStack {
            if let toast = browser.toasts.current {
                HStack(spacing: 9) {
                    Image(systemName: toast.symbol).font(.system(size: 13, weight: .medium))
                    Text(toast.message).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let action = toast.action {
                        Button(action) { browser.toasts.runAction() }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                .surface(.selected, radius: 19, lifted: true)
                .id(toast.id)
                .transition(Arrive(anchor: .bottom, scale: 0.94, rise: 10))
                .onTapGesture { animate(Motion.exit) { browser.toasts.dismiss() } }
            }
        }
        .motion(Motion.arrive, value: browser.toasts.current)
        .padding(.bottom, 22)
    }
}
