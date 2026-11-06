import Foundation
import SkylightCore

/// Describes a tool to an agent (the shape MCP's `tools/list` returns).
public struct ToolDefinition: Equatable, Sendable {
    public enum Risk: String, Sendable {
        /// Reads only. Runs without asking.
        case read
        /// Changes something (navigates, clicks, types, closes). Needs the user's approval.
        case write
    }

    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var risk: Risk
    /// The site that offered this tool, which wrote its name and description. Nil for Skylight's own.
    public var offeredBy: String?

    public init(name: String, description: String, inputSchema: JSONValue = ["type": "object", "properties": [:]], risk: Risk,
                offeredBy: String? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.risk = risk
        self.offeredBy = offeredBy
    }

    /// What the user is asked to allow, in Skylight's words: a page's own description of its tool
    /// could say anything. `site` is the page the call acts on.
    public func request(arguments a: JSONValue, site: String?) -> String {
        let on = site.map { " on \($0)" } ?? ""
        func text(_ key: String, _ fallback: String) -> String { a[key]?.stringValue.map { String($0.prefix(80)) } ?? fallback }
        func run(_ tool: String, _ site: String?, _ input: JSONValue) -> String {
            let details = ToolHub.summary(of: input)
            return "Run “\(tool.prefix(60))” on \(site ?? "this page")" + (details.isEmpty ? "" : " (\(details.prefix(160)))")
        }
        if let offeredBy { return run(name.components(separatedBy: "__").last ?? name, offeredBy, a) }
        switch name {
        case "open_tab": return "Open \(text("url", "a new tab"))"
        case "navigate": return "Go to \(text("url", "a page"))" + (site.map { " from \($0)" } ?? "")
        case "go_back": return "Go back\(on)"
        case "go_forward": return "Go forward\(on)"
        case "reload": return "Reload \(site ?? "a page")"
        case "select_tab": return "Switch to \(site ?? "a tab")"
        case "close_tab": return "Close \(site ?? "a tab")"
        case "switch_space": return "Switch to the \(text("space", "other")) Space"
        case "click": return "Click element \(text("ref", "?"))\(on)"
        case "type_text": return "Type “\(text("text", ""))”\(on)"
        case "scroll": return "Scroll \(site ?? "a page")"
        case "call_site_tool": return run(text("name", "a tool"), site, a["input"] ?? [:])
        case "run_package_command": return "Run \(text("command", "a command")) from \(text("package", "a package"))\(on)"
        default: return description
        }
    }
}

public struct ToolResult: Equatable, Sendable {
    public var content: JSONValue
    public var isError: Bool

    public init(content: JSONValue, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolResult { ToolResult(content: .string(message), isError: true) }

    /// The text an agent sees.
    public var text: String {
        if case let .string(s) = content { return s }
        return content.serialized(pretty: true)
    }
}

public struct ToolError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A tool and the code that runs it.
public struct AgentTool: Sendable {
    public var definition: ToolDefinition
    public var run: @MainActor @Sendable (JSONValue) async throws -> JSONValue

    public init(_ definition: ToolDefinition, run: @escaping @MainActor @Sendable (JSONValue) async throws -> JSONValue) {
        self.definition = definition
        self.run = run
    }
}

/// Who is asking, shown to the user when approval is needed.
public struct AgentClient: Equatable, Sendable {
    /// What the agent calls itself. Any agent can claim any name, so it's only for showing.
    public var name: String
    /// The MCP session Skylight gave this agent's connection: a secret only that connection holds,
    /// so it's what trust is kept against. Nil for a request outside a session.
    public var session: String?
    public init(name: String, session: String? = nil) {
        self.name = name
        self.session = session
    }
}

/// Asks the user before a `write` tool runs.
@MainActor
public protocol ApprovalProvider: AnyObject {
    func approve(tool: ToolDefinition, arguments: JSONValue, client: AgentClient) async -> Bool
}

/// What transports (MCP, an in-app agent) need from the tool registry.
@MainActor
public protocol ToolCatalog: AnyObject {
    func listTools() -> [ToolDefinition]
    func callTool(named name: String, arguments: JSONValue, client: AgentClient) async -> ToolResult
}

/// Activity the UI can show ("Claude Code clicked Book").
public struct AgentActivity: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let client: String
    public let tool: String
    public let summary: String
    public let succeeded: Bool
    public let date: Date
}

/// The registry every agent goes through. Static tools come from Skylight itself; providers add
/// tools that change at runtime (WebMCP tools from the open page).
@MainActor
public final class ToolHub: ToolCatalog {
    public typealias Provider = @MainActor () -> [AgentTool]

    private var tools: [String: AgentTool] = [:]
    private var order: [String] = []
    private var providers: [Provider] = []
    public weak var approvals: ApprovalProvider?
    public var onActivity: (@MainActor (AgentActivity) -> Void)?

    public init() {}

    public func register(_ tool: AgentTool) {
        if tools[tool.definition.name] == nil { order.append(tool.definition.name) }
        tools[tool.definition.name] = tool
    }

    public func register(_ list: [AgentTool]) { list.forEach(register) }

    public func addProvider(_ provider: @escaping Provider) { providers.append(provider) }

    private func allTools() -> [AgentTool] {
        order.compactMap { tools[$0] } + providers.flatMap { $0() }
    }

    public func listTools() -> [ToolDefinition] { allTools().map(\.definition) }

    public func callTool(named name: String, arguments: JSONValue, client: AgentClient) async -> ToolResult {
        guard let tool = allTools().first(where: { $0.definition.name == name }) else {
            return .error("Unknown tool \(name). Call tools/list to see what's available.")
        }
        if tool.definition.risk == .write {
            guard let approvals else { return .error("No one is available to approve \(name).") }
            guard await approvals.approve(tool: tool.definition, arguments: arguments, client: client) else {
                record(client, name, "declined by the user", false)
                return .error("The user declined \(name).")
            }
        }
        do {
            let output = try await tool.run(arguments)
            record(client, name, Self.summary(of: arguments), true)
            return ToolResult(content: output)
        } catch {
            record(client, name, error.localizedDescription, false)
            return .error(error.localizedDescription)
        }
    }

    private func record(_ client: AgentClient, _ tool: String, _ summary: String, _ ok: Bool) {
        onActivity?(AgentActivity(client: client.name, tool: tool, summary: summary, succeeded: ok, date: .now))
    }

    nonisolated static func summary(of arguments: JSONValue) -> String {
        guard let object = arguments.objectValue, !object.isEmpty else { return "" }
        return object.keys.sorted().compactMap { key in
            guard let value = object[key] else { return nil }
            let text = value.stringValue ?? value.serialized()
            return "\(key): \(text.prefix(60))"
        }.joined(separator: ", ")
    }
}

extension JSONValue {
    /// Reads a required string argument.
    public func requireString(_ key: String) throws -> String {
        guard let s = self[key]?.stringValue, !s.isEmpty else { throw ToolError("Missing \"\(key)\".") }
        return s
    }
}
