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
    /// `2026-01-01T09:30:00.250Z`.
    static let dateStyle = Date.ISO8601FormatStyle.iso8601.year().month().day()
        .time(includingFractionalSeconds: true).timeZone(separator: .omitted)

    public static var skylight: JSONEncoder {
        let e = JSONEncoder()
        // Milliseconds, so ordering by time survives a reload. Compact: it's written often.
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(JSONEncoder.dateStyle))
        }
        return e
    }
}

extension JSONDecoder {
    public static var skylight: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Files from before fractional seconds have none.
            if let date = try? Date(raw, strategy: JSONEncoder.dateStyle) { return date }
            if let date = try? Date(raw, strategy: .iso8601) { return date }
            if let date = try? Date(raw, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(raw)"))
        }
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
    /// Chromium only accepts profile folders directly inside its root. The default profile is
    /// Chromium's own first one, `Default`, which is also where extensions run.
    public func profileDirectory(for profile: ProfileID) -> URL {
        let name = profile == .standard ? "Default" : "Profile-\(profile.rawValue)"
        return engineRoot.appending(path: name, directoryHint: .isDirectory)
    }

    public var preferencesFile: URL { root.appending(path: "preferences.json") }
    public var mcpConnectionFile: URL { root.appending(path: "mcp.json") }
}
