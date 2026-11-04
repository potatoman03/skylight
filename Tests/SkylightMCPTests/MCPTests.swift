import Foundation
import Testing
@testable import SkylightAgent
@testable import SkylightCore
@testable import SkylightMCP

@MainActor
private final class Approver: ApprovalProvider {
    var answer: Bool
    var asked: [String] = []
    init(_ answer: Bool) { self.answer = answer }
    func approve(tool: ToolDefinition, arguments: JSONValue, client: AgentClient) async -> Bool {
        asked.append(tool.name)
        return answer
    }
}

@MainActor
private func makeHub(approve: Bool) -> (ToolHub, Approver) {
    let hub = ToolHub()
    let approver = Approver(approve)
    hub.approvals = approver
    hub.register(AgentTool(ToolDefinition(name: "echo", description: "Echoes", risk: .read)) { args in args })
    hub.register(AgentTool(ToolDefinition(name: "poke", description: "Changes", risk: .write)) { _ in "poked" })
    hub.register(AgentTool(ToolDefinition(name: "fail", description: "Throws", risk: .read)) { _ in throw ToolError("nope") })
    return (hub, approver)
}

@MainActor
@Suite struct ToolHubTests {
    let client = AgentClient(name: "test")

    @Test func readToolsRunWithoutApproval() async {
        let (hub, approver) = makeHub(approve: false)
        let result = await hub.callTool(named: "echo", arguments: ["x": 1], client: client)
        #expect(!result.isError)
        #expect(result.content == ["x": 1])
        #expect(approver.asked.isEmpty)
    }

    @Test func writeToolsNeedApproval() async {
        let (hub, approver) = makeHub(approve: false)
        let denied = await hub.callTool(named: "poke", arguments: [:], client: client)
        #expect(denied.isError)
        #expect(approver.asked == ["poke"])

        approver.answer = true
        let allowed = await hub.callTool(named: "poke", arguments: [:], client: client)
        #expect(allowed.content == "poked")
    }

    @Test func errorsAndUnknownTools() async {
        let (hub, _) = makeHub(approve: true)
        #expect(await hub.callTool(named: "fail", arguments: [:], client: client).text == "nope")
        #expect(await hub.callTool(named: "missing", arguments: [:], client: client).isError)
    }

    @Test func providersAddDynamicTools() async {
        let (hub, _) = makeHub(approve: true)
        hub.addProvider { [AgentTool(ToolDefinition(name: "site_x__y", description: "", risk: .read)) { _ in "site" }] }
        #expect(hub.listTools().map(\.name).contains("site_x__y"))
        #expect(await hub.callTool(named: "site_x__y", arguments: [:], client: client).content == "site")
    }
}

@MainActor
@Suite struct MCPHandlerTests {
    func handler() -> MCPRequestHandler {
        MCPRequestHandler(catalog: makeHub(approve: true).0, info: .init(name: "skylight", version: "1", instructions: "hi"))
    }

    func call(_ h: MCPRequestHandler, _ json: String) async -> JSONValue? {
        await h.handle(Data(json.utf8), client: AgentClient(name: "t")).response
    }

    @Test func initializeNegotiatesVersion() async {
        let h = handler()
        let outcome = await h.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"Claude Code"}}}"#.utf8),
                                     client: AgentClient(name: "t"))
        #expect(outcome.response?["result"]?["protocolVersion"] == "2025-03-26")
        #expect(outcome.initializedClient == "Claude Code")

        let future = await call(h, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(future?["result"]?["protocolVersion"]?.stringValue == MCPRequestHandler.protocolVersion)
    }

    @Test func listsAndCallsTools() async {
        let h = handler()
        let list = await call(h, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["echo", "poke", "fail"])
        #expect(list?["result"]?["tools"]?.arrayValue?.first?["annotations"]?["readOnlyHint"] == true)

        let result = await call(h, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fail","arguments":{}}}"#)
        #expect(result?["result"]?["isError"] == true)
        #expect(result?["result"]?["content"]?.arrayValue?.first?["text"] == "nope")
    }

    @Test func notificationsGetNoResponse() async {
        #expect(await call(handler(), #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func errors() async {
        let h = handler()
        #expect(await call(h, "not json")?["error"]?["code"] == -32700)
        #expect(await call(h, #"{"jsonrpc":"2.0","id":1,"method":"nope"}"#)?["error"]?["code"] == -32601)
        #expect(await call(h, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#)?["error"]?["code"] == -32602)
    }
}

@Suite struct HTTPAndSecurityTests {
    @Test func parsesCompleteRequests() {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nAuthorization: Bearer t\r\n\r\n{}"
        guard case let .complete(request) = HTTPServer.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer t")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForTheBody() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        guard case .incomplete = HTTPServer.parse(Data(raw.utf8)) else {
            Issue.record("expected incomplete")
            return
        }
    }

    @Test func rejectsHugeBodies() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        guard case .invalid(413) = HTTPServer.parse(Data(raw.utf8)) else {
            Issue.record("expected 413")
            return
        }
    }

    @Test func originsAndTokens() {
        #expect(MCPServer.isLocalOrigin("http://localhost:3000"))
        #expect(MCPServer.isLocalOrigin("http://127.0.0.1"))
        #expect(!MCPServer.isLocalOrigin("https://evil.example"))
        #expect(!MCPServer.isLocalOrigin("null"))
        #expect(MCPServer.constantTimeEquals("Bearer abc", "Bearer abc"))
        #expect(!MCPServer.constantTimeEquals("Bearer abc", "Bearer abd"))
        #expect(MCPServer.makeToken().count == 64)
    }
}

@Suite struct WebMCPTests {
    @Test func parsesPageTools() {
        let message: JSONValue = ["type": "webmcp.tools", "tools": [
            ["name": "search", "description": "Search", "readOnly": true],
            ["description": "no name"],
        ]]
        let tools = WebMCP.parseTools(message)
        #expect(tools.map(\.name) == ["search"])
        #expect(tools[0].readOnly)
    }

    @Test func exposedNamesAreMCPSafe() {
        let name = WebMCP.exposedName(host: "shop.example.com", tool: "add to cart!")
        #expect(name == "site_shop_example_com__add_to_cart_")
        #expect(WebMCP.exposedName(host: String(repeating: "a", count: 100), tool: "x").count == 64)
    }
}

@MainActor
@Suite struct MCPPerformanceTests {
    @Test func requestRoundTrips() async {
        let handler = MCPRequestHandler(catalog: makeHub(approve: true).0, info: .init(name: "skylight", version: "1", instructions: ""))
        let list = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let call = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"x":1}}}"#.utf8)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            for _ in 0..<1_000 {
                _ = await handler.handle(list, client: AgentClient(name: "bench"))
                _ = await handler.handle(call, client: AgentClient(name: "bench"))
            }
        }
        print("BENCH MCP tools/list + tools/call: \(elapsed / 1_000) per pair (n=1,000)")
        #expect(elapsed < .seconds(10))
    }
}
