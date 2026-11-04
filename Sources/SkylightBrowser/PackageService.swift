import AppKit
import Observation
import SkylightCore
import SkylightKit

/// Keeps installed packages loaded and live: watches the packages folder, reloads on change,
/// swaps CSS into open pages without a reload, and runs package commands.
@MainActor
@Observable
public final class PackageService {
    public private(set) var packages: [LoadedPackage] = []
    public private(set) var failures: [String: String] = [:]

    @ObservationIgnored public let directory: URL
    /// Called with the package scripts whenever they change, so the engine can inject them.
    @ObservationIgnored public var onScriptsChange: (@MainActor ([String]) -> Void)?
    /// Runs an expression in every awake page (used for live CSS).
    @ObservationIgnored public var evaluateEverywhere: (@MainActor (String) -> Void)?
    @ObservationIgnored private var watcher: DirectoryWatcher?

    public init(directory: URL) {
        self.directory = directory
    }

    public func start() {
        reload()
        watcher = DirectoryWatcher(directory: directory) { [weak self] in self?.reload() }
    }

    public func reload() {
        let report = PackageLoader(directory: directory).load()
        let old = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
        failures = report.failures
        guard report.packages != packages else { return }

        let scriptsChanged = report.packages.map(\.scripts) != packages.map(\.scripts)
            || report.packages.map(\.matchers) != packages.map(\.matchers)
            || report.packages.map(\.id) != packages.map(\.id)
        packages = report.packages
        onScriptsChange?(PackageScripts.scripts(for: packages))

        // CSS-only edits apply instantly to open pages.
        if !scriptsChanged {
            for pkg in packages where old[pkg.id]?.css != pkg.css {
                evaluateEverywhere?(PackageScripts.updateStyle(packageID: pkg.id, css: pkg.css))
            }
        }
    }

    public var scripts: [String] { PackageScripts.scripts(for: packages) }

    /// Commands that apply to `url`, for the command bar.
    public func commands(for url: URL?) -> [(package: LoadedPackage, command: PackageManifest.Command)] {
        packages.filter { url.map($0.applies(to:)) ?? false }
            .flatMap { pkg in pkg.manifest.commands.map { (pkg, $0) } }
    }

    /// Creates a boost for `host` and opens its folder.
    @discardableResult
    public func createBoost(for host: String) throws -> URL {
        let folder = try BoostTemplate.create(forHost: host, in: directory)
        NSWorkspace.shared.open(folder.appending(path: "style.css"))
        reload()
        return folder
    }

    public func revealInFinder(_ package: LoadedPackage? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([package?.directory ?? directory])
    }
}
