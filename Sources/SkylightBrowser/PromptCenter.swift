import Foundation
import Observation
import SkylightAgent
import SkylightCore
import SkylightEngine

/// Something waiting on the user: a site permission, a page dialog, or an agent action.
public enum Prompt: Identifiable {
    case permission(TabID, PermissionRequest)
    case dialog(TabID, DialogRequest)
    case approval(AgentApproval)

    public var id: String {
        switch self {
        case let .permission(_, r): "permission-\(r.id)"
        case let .dialog(_, r): "dialog-\(r.id)"
        case let .approval(a): "approval-\(a.id)"
        }
    }

    /// The tab the prompt belongs to; nil for agent approvals, which show over any tab.
    public var tabID: TabID? {
        switch self {
        case let .permission(id, _), let .dialog(id, _): id
        case .approval: nil
        }
    }
}

public struct AgentApproval: Identifiable, Sendable {
    public let id = UUID()
    public let client: String
    /// The agent's MCP session, which "Allow for This Session" trusts. Nil outside a session,
    /// where there's nothing to trust.
    public let session: String?
    public let tool: ToolDefinition
    public let summary: String
}

/// Queues prompts and resolves them. The UI shows the first prompt for the visible tab, plus any
/// agent approval.
@MainActor
@Observable
public final class PromptCenter: ApprovalProvider {
    public private(set) var prompts: [Prompt] = []

    /// Asking site + the page's site + permission kind → the user's answer, for this run of the app.
    @ObservationIgnored private var permissionAnswers: [String: Bool] = [:]

    private static func keys(_ request: PermissionRequest) -> [String] {
        let pair = "\(PermissionRequest.origin(of: request.origin)) in \(PermissionRequest.origin(of: request.topOrigin))"
        return request.kinds.map { "\(pair)|\($0.rawValue)" }
    }
    /// Agent sessions the user allowed to act without asking, with the agents' names, for this
    /// run of the app. Kept by session, not name: another agent could call itself the same.
    @ObservationIgnored private var trustedSessions: [String: String] = [:] { didSet { trustedClients = Set(trustedSessions.values) } }
    /// The names of agents allowed to act without asking, to show.
    public private(set) var trustedClients: Set<String> = []
    @ObservationIgnored private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// The site a tool call would act on, to name when asking.
    @ObservationIgnored public var siteOfCall: @MainActor (JSONValue) -> String? = { _ in nil }

    public init() {}

    public func prompt(for tab: TabID?) -> Prompt? {
        prompts.first { $0.tabID == nil } ?? prompts.first { $0.tabID != nil && $0.tabID == tab }
    }

    // MARK: Permissions

    public func enqueue(_ request: PermissionRequest, tab: TabID) {
        let keys = Self.keys(request)
        let answers = keys.compactMap { permissionAnswers[$0] }
        if answers.count == keys.count, !keys.isEmpty {
            request.respond(answers.allSatisfy { $0 })
            return
        }
        prompts.append(.permission(tab, request))
    }

    public func answer(permission request: PermissionRequest, allow: Bool, remember: Bool) {
        if remember { for key in Self.keys(request) { permissionAnswers[key] = allow } }
        request.respond(allow)
        prompts.removeAll { $0.id == "permission-\(request.id)" }
    }

    // MARK: Dialogs

    public func enqueue(_ request: DialogRequest, tab: TabID) {
        prompts.append(.dialog(tab, request))
    }

    public func answer(dialog request: DialogRequest, ok: Bool, text: String = "") {
        request.respond(ok, text)
        prompts.removeAll { $0.id == "dialog-\(request.id)" }
    }

    // MARK: Agent approvals

    public func approve(tool: ToolDefinition, arguments: JSONValue, client: AgentClient) async -> Bool {
        if let session = client.session, trustedSessions[session] != nil { return true }
        let approval = AgentApproval(client: client.name, session: client.session, tool: tool,
                                     summary: tool.request(arguments: arguments, site: siteOfCall(arguments)))
        // Agents give up on slow calls; don't leave a stale card behind.
        Task { [weak self] in
            try? await Task.sleep(for: Self.approvalTimeout)
            self?.answer(approval: approval, allow: false)
        }
        return await withCheckedContinuation { continuation in
            approvalContinuations[approval.id] = continuation
            prompts.append(.approval(approval))
        }
    }

    static let approvalTimeout: Duration = .seconds(120)

    public func answer(approval: AgentApproval, allow: Bool, trustClient: Bool = false) {
        if allow && trustClient, let session = approval.session { trustedSessions[session] = approval.client }
        prompts.removeAll { $0.id == "approval-\(approval.id)" }
        approvalContinuations.removeValue(forKey: approval.id)?.resume(returning: allow)
    }

    public func revokeTrust() { trustedSessions.removeAll() }

    /// Drops prompts for a tab that closed, answering them negatively.
    public func dismissAll(for tab: TabID) {
        for prompt in prompts where prompt.tabID == tab {
            switch prompt {
            case let .permission(_, r): r.respond(false)
            case let .dialog(_, r): r.respond(false, "")
            case .approval: break
            }
        }
        prompts.removeAll { $0.tabID == tab }
    }
}

/// Short-lived messages ("Downloaded report.pdf").
@MainActor
@Observable
public final class ToastCenter {
    public struct Toast: Identifiable, Equatable {
        public let id = UUID()
        public let symbol: String
        public let message: String
        public var action: String?
        public static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    public private(set) var current: Toast?
    @ObservationIgnored private var actions: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ message: String, symbol: String = "checkmark.circle", action: (title: String, run: @MainActor () -> Void)? = nil) {
        let toast = Toast(symbol: symbol, message: message, action: action?.title)
        actions = action.map { [toast.id: $0.run] } ?? [:]
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    public func runAction() {
        guard let current, let run = actions[current.id] else { return }
        run()
        dismiss()
    }

    public func dismiss() {
        current = nil
        actions = [:]
    }
}
