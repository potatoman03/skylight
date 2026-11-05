import Foundation
import Observation
import SkylightAgent
import SkylightCore
import SkylightEngine
import SkylightKit

/// Skylight's built-in agent tools, plus the WebMCP tools pages register.
/// Every transport (MCP today, an in-app agent later) goes through `hub`.
@MainActor
@Observable
public final class AgentService {
    @ObservationIgnored public let hub = ToolHub()
    public private(set) var activity: [AgentActivity] = []
    /// Tools each tab's page registered through `navigator.modelContext`.
    public private(set) var siteTools: [TabID: [WebMCP.PageTool]] = [:]

    @ObservationIgnored private let store: BrowserStore
    @ObservationIgnored private let pages: PageCoordinator
    @ObservationIgnored private let packages: PackageService
    @ObservationIgnored private let makeOmnibox: @MainActor () -> Omnibox
    private var omnibox: Omnibox { makeOmnibox() }

    public init(store: BrowserStore, pages: PageCoordinator, packages: PackageService, omnibox: @escaping @MainActor () -> Omnibox,
                approvals: ApprovalProvider) {
        self.store = store
        self.pages = pages
        self.packages = packages
        self.makeOmnibox = omnibox
        hub.approvals = approvals
        hub.onActivity = { [weak self] event in
            guard let self else { return }
            self.activity = Array(([event] + self.activity).prefix(50))
        }
        hub.register(builtInTools())
        hub.addProvider { [weak self] in self?.selectedSiteTools() ?? [] }
    }

    /// Page scripts agents rely on.
    public static let pageScripts = [WebMCP.polyfill]

    // MARK: - WebMCP

    public func updateSiteTools(_ tools: [WebMCP.PageTool], tab: TabID) {
        siteTools[tab] = tools.isEmpty ? nil : tools
    }

    public func forgetTab(_ tab: TabID) { siteTools[tab] = nil }

    /// The selected tab's WebMCP tools, exposed as first-class tools.
    private func selectedSiteTools() -> [AgentTool] {
        guard let tab = store.state.selectedTab, let tools = siteTools[tab.id] else { return [] }
        let host = tab.url.host() ?? "site"
        return tools.map { tool in
            let definition = ToolDefinition(
                name: WebMCP.exposedName(host: host, tool: tool.name),
                description: "[\(host), offered by the page] \(tool.description)",
                inputSchema: tool.inputSchema, risk: tool.readOnly ? .read : .write)
            let tabID = tab.id
            return AgentTool(definition) { [weak self] input in
                guard let self else { throw ToolError("Skylight is shutting down.") }
                return try await self.callSiteTool(tab: tabID, name: tool.name, input: input)
            }
        }
    }

    private func callSiteTool(tab: TabID, name: String, input: JSONValue) async throws -> JSONValue {
        guard let page = pages.page(for: tab) else { throw ToolError("That tab is asleep. Select it first.") }
        return try await page.evaluate(WebMCP.call(name: name, input: input))
    }

    // MARK: - Built-in tools

    private func resolveTab(_ args: JSONValue) throws -> TabID {
        if let raw = args["tab_id"]?.stringValue, !raw.isEmpty {
            let id = TabID(raw)
            guard store.state.tabs[id] != nil else { throw ToolError("No tab \(raw). Call list_tabs.") }
            return id
        }
        guard let id = store.state.selectedTabID else { throw ToolError("No tab is selected. Pass tab_id or open_tab first.") }
        return id
    }

    private func describe(_ tab: Tab, in space: Space) -> JSONValue {
        var item: JSONValue = [
            "tab_id": .string(tab.id.rawValue), "title": .string(tab.displayTitle), "url": .string(tab.url.absoluteString),
            "section": .string(store.state.isFavorite(tab.id) ? "favorite" : space.section(of: tab.id)?.rawValue ?? "today"),
            "selected": .bool(space.selectedTabID == tab.id),
            "awake": .bool(store.status(of: tab.id).isAwake),
        ]
        if let tools = siteTools[tab.id] { item = merge(item, ["site_tools": .array(tools.map { .string($0.name) })]) }
        return item
    }

    private func merge(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        .object((a.objectValue ?? [:]).merging(b.objectValue ?? [:]) { _, new in new })
    }

    private func page(_ tab: TabID) async throws -> WebPage {
        guard let page = pages.wake(tab) else { throw ToolError("Couldn't open that tab's page.") }
        await pages.waitUntilLoaded(tab)
        return page
    }

    static let tabArg: JSONValue = ["type": "string", "description": "A tab_id from list_tabs. Defaults to the selected tab."]

    private func builtInTools() -> [AgentTool] {
        [
            AgentTool(ToolDefinition(
                name: "list_tabs",
                description: "Lists the tabs in every Space, with ids, titles, URLs, sections (favorite, pinned or today) and which one is selected.",
                risk: .read)) { [unowned self] _ in
                let state = self.store.state
                let spaces: [JSONValue] = state.spaces.map { space in
                    [
                        "space_id": .string(space.id.rawValue), "space": .string(space.name),
                        "profile": .string(state.profile(space.profileID)?.name ?? "Default"),
                        "active": .bool(space.id == state.activeSpaceID),
                        "tabs": .array(space.allTabIDs.compactMap { state.tabs[$0] }.map { self.describe($0, in: space) }),
                    ]
                }
                return ["spaces": .array(spaces)]
            },
            AgentTool(ToolDefinition(
                name: "open_tab",
                description: "Opens a URL, or searches for text, in a new tab of the active Space.",
                inputSchema: ["type": "object", "properties": [
                    "url": ["type": "string", "description": "A URL, or words to search for."],
                    "background": ["type": "boolean", "description": "Open without selecting it."],
                ], "required": ["url"]],
                risk: .write)) { [unowned self] args in
                let input = try args.requireString("url")
                guard let url = self.omnibox.interpret(input)?.url else { throw ToolError("Couldn't make a URL from \(input).") }
                let result = self.store.send(.openTab(url, select: !(args["background"]?.boolValue ?? false)))
                guard let id = result.openedTabID else { throw ToolError("Couldn't open the tab.") }
                return ["tab_id": .string(id.rawValue), "url": .string(url.absoluteString)]
            },
            AgentTool(ToolDefinition(
                name: "navigate", description: "Loads a URL in a tab.",
                inputSchema: ["type": "object", "properties": ["tab_id": Self.tabArg, "url": ["type": "string"]], "required": ["url"]],
                risk: .write)) { [unowned self] args in
                let id = try self.resolveTab(args)
                let input = try args.requireString("url")
                guard let url = self.omnibox.interpret(input)?.url else { throw ToolError("Couldn't make a URL from \(input).") }
                self.store.send(.navigate(id, url))
                await self.pages.waitUntilLoaded(id)
                return ["tab_id": .string(id.rawValue), "url": .string(self.store.state.tabs[id]?.url.absoluteString ?? url.absoluteString)]
            },
            simple("go_back", "Goes back in a tab's history.") { .goBack($0) },
            simple("go_forward", "Goes forward in a tab's history.") { .goForward($0) },
            simple("reload", "Reloads a tab.") { .reload($0) },
            simple("select_tab", "Selects a tab, switching Space if needed.") { .selectTab($0) },
            simple("close_tab", "Closes a tab. The user can reopen it with ⌘⇧T.") { .closeTab($0) },
            AgentTool(ToolDefinition(
                name: "switch_space", description: "Switches to another Space by id or name.",
                inputSchema: ["type": "object", "properties": ["space": ["type": "string"]], "required": ["space"]],
                risk: .write)) { [unowned self] args in
                let key = try args.requireString("space")
                guard let space = self.store.state.spaces.first(where: { $0.id.rawValue == key || $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame })
                else { throw ToolError("No Space \(key). Call list_tabs.") }
                self.store.send(.switchSpace(space.id))
                return ["space": .string(space.name)]
            },
            AgentTool(ToolDefinition(
                name: "read_page",
                description: "Returns a tab's text and its interactive elements. Each element has a ref to use with click and type_text. Refs change when the page does, so read again after acting.",
                inputSchema: ["type": "object", "properties": ["tab_id": Self.tabArg]],
                risk: .read)) { [unowned self] args in
                let id = try self.resolveTab(args)
                var snapshot = try await self.page(id).evaluate(AgentPageScripts.snapshot)
                if let tools = self.siteTools[id] {
                    snapshot = self.merge(snapshot, ["site_tools": .array(tools.map {
                        ["name": .string($0.name), "description": .string($0.description)]
                    })])
                }
                return snapshot
            },
            AgentTool(ToolDefinition(
                name: "click", description: "Clicks an element by the ref read_page returned.",
                inputSchema: ["type": "object", "properties": ["tab_id": Self.tabArg, "ref": ["type": "string"]], "required": ["ref"]],
                risk: .write)) { [unowned self] args in
                let id = try self.resolveTab(args)
                let result = try await self.page(id).evaluate(AgentPageScripts.click(ref: try args.requireString("ref")))
                await self.pages.waitUntilLoaded(id, timeout: .seconds(5))
                return result
            },
            AgentTool(ToolDefinition(
                name: "type_text", description: "Types into a field by the ref read_page returned, replacing what's there. Set submit to press Enter.",
                inputSchema: ["type": "object", "properties": [
                    "tab_id": Self.tabArg, "ref": ["type": "string"], "text": ["type": "string"], "submit": ["type": "boolean"],
                ], "required": ["ref", "text"]],
                risk: .write)) { [unowned self] args in
                let id = try self.resolveTab(args)
                let script = AgentPageScripts.type(ref: try args.requireString("ref"), text: args["text"]?.stringValue ?? "",
                                                   submit: args["submit"]?.boolValue ?? false)
                let result = try await self.page(id).evaluate(script)
                if args["submit"]?.boolValue == true { await self.pages.waitUntilLoaded(id) }
                return result
            },
            AgentTool(ToolDefinition(
                name: "scroll", description: "Scrolls a tab by a number of pixels (negative scrolls up).",
                inputSchema: ["type": "object", "properties": ["tab_id": Self.tabArg, "pixels": ["type": "number"]], "required": ["pixels"]],
                risk: .read)) { [unowned self] args in
                let id = try self.resolveTab(args)
                return try await self.page(id).evaluate(AgentPageScripts.scroll(by: args["pixels"]?.intValue ?? 600))
            },
            AgentTool(ToolDefinition(
                name: "call_site_tool",
                description: "Calls a WebMCP tool a page registered through navigator.modelContext (see site_tools in list_tabs or read_page).",
                inputSchema: ["type": "object", "properties": [
                    "tab_id": Self.tabArg, "name": ["type": "string"], "input": ["type": "object"],
                ], "required": ["name"]],
                risk: .write)) { [unowned self] args in
                let id = try self.resolveTab(args)
                let name = try args.requireString("name")
                guard self.siteTools[id]?.contains(where: { $0.name == name }) == true else {
                    throw ToolError("That page doesn't offer \(name).")
                }
                _ = try await self.page(id)
                return try await self.callSiteTool(tab: id, name: name, input: args["input"] ?? [:])
            },
            AgentTool(ToolDefinition(
                name: "run_package_command", description: "Runs a command from an installed Skylight package in a tab.",
                inputSchema: ["type": "object", "properties": [
                    "tab_id": Self.tabArg, "package": ["type": "string"], "command": ["type": "string"],
                ], "required": ["package", "command"]],
                risk: .write)) { [unowned self] args in
                let id = try self.resolveTab(args)
                return try await self.page(id).evaluate(
                    PackageScripts.runCommand(packageID: try args.requireString("package"), commandID: try args.requireString("command")))
            },
            AgentTool(ToolDefinition(
                name: "list_packages", description: "Lists installed Skylight packages and their commands.",
                risk: .read)) { [unowned self] _ in
                .array(self.packages.packages.map { pkg in
                    [
                        "id": .string(pkg.id), "name": .string(pkg.manifest.name),
                        "matches": .array(pkg.manifest.matches.map { .string($0) }),
                        "commands": .array(pkg.manifest.commands.map { ["id": .string($0.id), "title": .string($0.title)] }),
                    ]
                })
            },
        ]
    }

    private func simple(_ name: String, _ description: String, _ action: @escaping @MainActor (TabID) -> BrowserAction) -> AgentTool {
        AgentTool(ToolDefinition(name: name, description: description,
                                 inputSchema: ["type": "object", "properties": ["tab_id": Self.tabArg]], risk: .write)) { [unowned self] args in
            let id = try self.resolveTab(args)
            self.store.send(action(id))
            return ["tab_id": .string(id.rawValue), "ok": true]
        }
    }
}
