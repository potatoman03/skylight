import Foundation
import Security
import SkylightAgent
import SkylightCore

/// How an agent connects. Written to `mcp.json` so tools and scripts can find the server.
public struct MCPConnection: Codable, Equatable, Sendable {
    public var url: String
    public var token: String

    /// The Claude Code command that registers Skylight.
    public var claudeCommand: String {
        "claude mcp add --transport http skylight \(url) --header \"Authorization: Bearer \(token)\""
    }
}

/// Serves Skylight's tools over MCP Streamable HTTP (JSON responses, no SSE) on localhost.
///
/// Every request needs the bearer token from `mcp.json`, and requests with a non-local `Origin`
/// are refused, so web pages can't reach the server through DNS rebinding.
@MainActor
public final class MCPServer {
    public static let defaultPort: UInt16 = 47_831

    public private(set) var connection: MCPConnection?
    private let handler: MCPRequestHandler
    private let connectionFile: URL
    private let token: String
    private var http: HTTPServer?
    /// Session ID → client name from `initialize`.
    private var sessions: [String: String] = [:]

    public init(catalog: ToolCatalog, info: MCPRequestHandler.ServerInfo, connectionFile: URL) {
        self.handler = MCPRequestHandler(catalog: catalog, info: info)
        self.connectionFile = connectionFile
        // Keep the token across launches so a registered agent keeps working.
        let saved = (try? Data(contentsOf: connectionFile)).flatMap { try? JSONDecoder().decode(MCPConnection.self, from: $0) }
        self.token = saved?.token ?? Self.makeToken()
    }

    public func start(port: UInt16 = defaultPort, ready: @escaping @MainActor (MCPConnection?) -> Void = { _ in }) {
        let server = HTTPServer { [weak self] request in
            guard let self else { return .text("", status: 503) }
            return await self.respond(to: request)
        }
        http = server
        server.start(preferredPort: port) { [weak self] bound in
            Task { @MainActor in
                guard let self else { return }
                guard let bound else { return ready(nil) }
                let connection = MCPConnection(url: "http://127.0.0.1:\(bound)/mcp", token: self.token)
                self.connection = connection
                self.writeConnectionFile(connection)
                ready(connection)
            }
        }
    }

    public func stop() {
        http?.stop()
        http = nil
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let refusal = precheck(request) { return refusal }
        return await route(request)
    }

    /// Auth and origin checks. Returns a response when the request must be refused.
    func precheck(_ request: HTTPRequest) -> HTTPResponse? {
        if let origin = request.headers["origin"], !Self.isLocalOrigin(origin) {
            return .text("Origin not allowed", status: 403)
        }
        guard request.path == "/mcp" else { return .text("Not found", status: 404) }
        guard Self.constantTimeEquals(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            return .text("Missing or wrong bearer token", status: 401)
        }
        return nil
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch request.method {
        case "POST":
            return await handlePost(request)
        case "DELETE":
            sessions.removeValue(forKey: request.headers["mcp-session-id"] ?? "")
            return HTTPResponse(status: 200)
        default:
            // GET would open an SSE stream for server-initiated messages, which Skylight doesn't send.
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }
    }

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.headers["mcp-session-id"].flatMap { sessions[$0] != nil ? $0 : nil }
        let clientName = sessionID.flatMap { sessions[$0] } ?? request.headers["user-agent"] ?? "An agent"
        let outcome = await handler.handle(request.body, client: AgentClient(name: clientName, session: sessionID))

        var headers: [String: String] = [:]
        if outcome.response?["result"]?["serverInfo"] != nil {
            let name = outcome.initializedClient ?? clientName
            let id = UUID().uuidString
            sessions[id] = name
            headers["Mcp-Session-Id"] = id
        }
        guard let response = outcome.response else { return HTTPResponse(status: 202) }
        return .json(response.serialized(), headers: headers)
    }

    private func writeConnectionFile(_ connection: MCPConnection) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(connection) else { return }
        try? FileManager.default.createDirectory(at: connectionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: connectionFile, options: .atomic)
        // The token grants control of the browser: owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionFile.path)
    }

    nonisolated static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isLocalOrigin(_ origin: String) -> Bool {
        guard origin != "null", let host = URL(string: origin)?.host() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }

    nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
