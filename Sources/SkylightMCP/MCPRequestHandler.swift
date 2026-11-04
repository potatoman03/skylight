import Foundation
import SkylightAgent
import SkylightCore

/// JSON-RPC for the Model Context Protocol, independent of the transport.
/// Handles `initialize`, `ping`, `tools/list` and `tools/call`.
@MainActor
public final class MCPRequestHandler {
    public static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    public struct ServerInfo: Sendable {
        public var name: String
        public var version: String
        public var instructions: String
        public init(name: String, version: String, instructions: String) {
            self.name = name
            self.version = version
            self.instructions = instructions
        }
    }

    /// What a request produced: a JSON-RPC response, or nothing for a notification.
    public struct Outcome: Sendable {
        public var response: JSONValue?
        /// The client's name when this request was `initialize`.
        public var initializedClient: String?
    }

    private let catalog: ToolCatalog
    private let info: ServerInfo

    public init(catalog: ToolCatalog, info: ServerInfo) {
        self.catalog = catalog
        self.info = info
    }

    enum Code {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    public func handle(_ body: Data, client: AgentClient) async -> Outcome {
        guard let message = try? JSONValue.parse(body) else {
            return Outcome(response: Self.error(id: .null, code: Code.parse, "Invalid JSON."))
        }
        return await handle(message, client: client)
    }

    public func handle(_ message: JSONValue, client: AgentClient) async -> Outcome {
        guard message.objectValue != nil, let method = message["method"]?.stringValue else {
            // A response from the client (we never send requests) or garbage.
            if message["result"] != nil || message["error"] != nil { return Outcome() }
            return Outcome(response: Self.error(id: message["id"] ?? .null, code: Code.invalidRequest, "Expected a JSON-RPC request."))
        }
        let params = message["params"] ?? [:]
        guard let id = message["id"] else {
            return Outcome() // Notification: notifications/initialized, cancelled, …
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.protocolVersion
            let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
            let result: JSONValue = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(info.name), "version": .string(info.version)],
                "instructions": .string(info.instructions),
            ]
            return Outcome(response: Self.result(id: id, result),
                           initializedClient: params["clientInfo"]?["name"]?.stringValue)

        case "ping":
            return Outcome(response: Self.result(id: id, [:]))

        case "tools/list":
            let tools = catalog.listTools().map { tool -> JSONValue in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": ["readOnlyHint": .bool(tool.risk == .read)],
                ]
            }
            return Outcome(response: Self.result(id: id, ["tools": .array(tools)]))

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Outcome(response: Self.error(id: id, code: Code.invalidParams, "tools/call needs a name."))
            }
            let output = await catalog.callTool(named: name, arguments: params["arguments"] ?? [:], client: client)
            let result: JSONValue = [
                "content": [["type": "text", "text": .string(output.text)]],
                "isError": .bool(output.isError),
            ]
            return Outcome(response: Self.result(id: id, result))

        default:
            return Outcome(response: Self.error(id: id, code: Code.methodNotFound, "Skylight doesn't support \(method)."))
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
