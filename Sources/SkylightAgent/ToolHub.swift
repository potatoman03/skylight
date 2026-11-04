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

    public init(name: String, description: String, inputSchema: JSONValue = ["type": "object", "properties": [:]], risk: Risk) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.risk = risk
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
    public var name: String
    public init(name: String) { self.name = name }
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

    static func summary(of arguments: JSONValue) -> String {
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
