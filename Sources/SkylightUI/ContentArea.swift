import AppKit
import SkylightBrowser
import SkylightCore
import SkylightEngine
import SwiftUI

/// The page card: the engine's view, rounded and floating on the backdrop, with the progress
/// line, prompts and the empty state on top.
struct ContentArea: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let tab = browser.store.state.selectedTab
        let status = browser.selectedStatus
        let prompt = browser.prompts.prompt(for: browser.pages.visibleTabID)

        ZStack(alignment: .top) {
            PageHost(view: browser.pages.hostView)
            if tab == nil {
                StartView().transition(.opacity)
            }
            ProgressLine(progress: status.progress, loading: status.isLoading)
            if let prompt {
                PromptCard(prompt: prompt)
                    .id(prompt.id)
                    .padding(.top, 14)
                    .transition(Arrive(anchor: .top, scale: 0.96, rise: -8))
            }
        }
        .motion(Motion.arrive, value: prompt?.id)
        .motion(Motion.swap, value: tab == nil)
        .background(.background)
        .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

/// Hosts the coordinator's page container. SwiftUI never re-creates it, so pages keep running.
struct PageHost: NSViewRepresentable {
    let view: PageHostView

    func makeNSView(context: Context) -> PageHostView {
        view.wantsLayer = true
        view.layer?.cornerRadius = Theme.cardRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: PageHostView, context: Context) {}
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

private struct StartView: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sun.horizon")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("Skylight").font(.system(size: 22, weight: .semibold, design: .rounded))
            Button("New Tab") { browser.presentCommandBar(.newTab) }
                .buttonStyle(.glass)
                .keyboardShortcut("t", modifiers: .command)
            Text("⌘T to search or open a site · ⌘L to edit the address")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
                .glassEffect(.regular, in: .capsule)
                .id(toast.id)
                .transition(Arrive(anchor: .bottom, scale: 0.94, rise: 10))
                .onTapGesture { animate(Motion.exit) { browser.toasts.dismiss() } }
            }
        }
        .motion(Motion.arrive, value: browser.toasts.current)
        .padding(.bottom, 22)
    }
}
