import Foundation

/// Reads every package folder inside a directory.
public struct PackageLoader: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public struct Report: Sendable, Equatable {
        public var packages: [LoadedPackage] = []
        /// Folder name → why it was skipped.
        public var failures: [String: String] = [:]
    }

    public func load() -> Report {
        var report = Report()
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        var seen = Set<String>()
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            switch loadPackage(at: folder) {
            case let .success(pkg):
                if seen.insert(pkg.id).inserted {
                    report.packages.append(pkg)
                } else {
                    report.failures[folder.lastPathComponent] = "duplicate id \(pkg.id)"
                }
            case let .failure(error):
                report.failures[folder.lastPathComponent] = error.message
            }
        }
        return report
    }

    public struct LoadError: Error, Equatable { public let message: String }

    public func loadPackage(at folder: URL) -> Result<LoadedPackage, LoadError> {
        let manifestURL = folder.appending(path: PackageManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .failure(LoadError(message: "missing \(PackageManifest.fileName)"))
        }
        let manifest: PackageManifest
        do {
            manifest = try JSONDecoder().decode(PackageManifest.self, from: data)
        } catch {
            return .failure(LoadError(message: "unreadable manifest: \(error.localizedDescription)"))
        }
        let problems = manifest.validate()
        guard problems.isEmpty else { return .failure(LoadError(message: problems.joined(separator: "; "))) }

        func read(_ file: String) -> Result<String, LoadError> {
            guard let s = try? String(contentsOf: folder.appending(path: file), encoding: .utf8) else {
                return .failure(LoadError(message: "can't read \(file)"))
            }
            return .success(s)
        }

        var css: [String] = []
        for file in manifest.styles {
            switch read(file) {
            case let .success(s): css.append(s)
            case let .failure(e): return .failure(e)
            }
        }
        var scripts: [String] = []
        for file in manifest.scripts {
            switch read(file) {
            case let .success(s): scripts.append(s)
            case let .failure(e): return .failure(e)
            }
        }
        return .success(LoadedPackage(
            manifest: manifest, directory: folder,
            css: css.joined(separator: "\n"), scripts: scripts,
            matchers: manifest.matches.compactMap(MatchPattern.init)
        ))
    }
}

/// Creates a new boost (a CSS-only package for one site) on disk.
public enum BoostTemplate {
    public static func create(forHost host: String, in directory: URL) throws -> URL {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let slug = bare.replacingOccurrences(of: ".", with: "-")
        var folder = directory.appending(path: "boost-\(slug)", directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = directory.appending(path: "boost-\(slug)-\(n)", directoryHint: .isDirectory)
            n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let manifest = PackageManifest(
            id: "boost.\(slug)", name: "Boost for \(bare)", matches: ["*://*.\(bare)/*"],
            styles: ["style.css"], scripts: ["page.js"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: folder.appending(path: PackageManifest.fileName))
        try """
        /* Styles for \(bare). Saved changes apply right away. */

        """.write(to: folder.appending(path: "style.css"), atomically: true, encoding: .utf8)
        try """
        // Runs at document start on \(bare). `skylight` is this package's API:
        //   skylight.command('id', () => { ... })   // also list it under "commands" in skylight.json
        //   skylight.addStyle('css')
        //   skylight.onReady(() => { ... })         // after the DOM is parsed

        """.write(to: folder.appending(path: "page.js"), atomically: true, encoding: .utf8)
        return folder
    }
}
