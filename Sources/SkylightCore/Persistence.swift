import Foundation

/// Where browser state lives between launches.
public protocol StateStore: Sendable {
    func load() throws -> BrowserState?
    func save(_ state: BrowserState) throws
}

/// Stores state as one JSON file, written atomically.
public struct JSONFileStateStore: StateStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> BrowserState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var state = try JSONDecoder.skylight.decode(BrowserState.self, from: Data(contentsOf: fileURL))
        state.normalize()
        return state
    }

    public func save(_ state: BrowserState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.skylight.encode(state).write(to: fileURL, options: .atomic)
    }
}

/// Keeps state in memory. Used by tests and previews.
public final class InMemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrowserState?

    public init(_ state: BrowserState? = nil) { stored = state }

    public func load() throws -> BrowserState? { lock.withLock { stored } }
    public func save(_ state: BrowserState) throws { lock.withLock { stored = state } }
}

extension JSONEncoder {
    public static var skylight: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    public static var skylight: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Well-known locations under Application Support.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard(appName: String = "Skylight") -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appending(path: appName, directoryHint: .isDirectory))
    }

    public var stateFile: URL { root.appending(path: "state.json") }
    public var packagesDirectory: URL { root.appending(path: "Packages", directoryHint: .isDirectory) }
    public var engineRoot: URL { root.appending(path: "Engine", directoryHint: .isDirectory) }
    public func profileDirectory(for space: SpaceID) -> URL {
        engineRoot.appending(path: "Spaces/\(space.rawValue)", directoryHint: .isDirectory)
    }
    public var mcpConnectionFile: URL { root.appending(path: "mcp.json") }
}
