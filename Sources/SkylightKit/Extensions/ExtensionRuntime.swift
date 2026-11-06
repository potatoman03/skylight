import CryptoKit
import Foundation

/// Gets a Chrome extension ready to run on WebKit. WebKit leaves out a few Chrome APIs, and an
/// extension's service worker dies if it touches one while it starts, which takes the whole
/// extension down. Nothing can be injected ahead of an extension's scripts, so an extension with a
/// worker runs from a copy that loads `compatibility` first: in its worker, its pages and its
/// content scripts. The folder it was installed in stays as it was.
public enum ExtensionRuntime {
    static let compatibilityFile = "skylight-compatibility.js"
    static let workerFile = "skylight-worker.js"

    /// Stands in for what's missing: events that never fire, and answers saying there's nothing
    /// there. Offscreen documents can't be made, so asking for one fails as it would for any other
    /// reason. Extensions already have to handle that.
    static let compatibility = """
    (() => {
      const api = globalThis.chrome;
      if (!api || !api.runtime) return;
      // WebKit holds its API objects' script wrappers weakly, so a wrapper nothing refers to is
      // collected and the next read gets a new one, without what was added to it here.
      Object.defineProperty(api, Symbol('skylight.runtime'), { value: api.runtime });
      // WebKit delivers events through these globals, in workers, pages and content scripts alike.
      // Proton Pass replaces them with a guard once it's running, and a script that does that
      // never hears anything again.
      if (Object.getOwnPropertyDescriptor(globalThis, 'chrome')?.configurable === false) return;
      for (const name of ['chrome', 'browser']) {
        Object.defineProperty(globalThis, name, { get: () => api, set: () => {}, configurable: false });
      }
      const add = (object, name, value) => { if (!(name in object)) object[name] = value; };
      const event = () => {
        const listeners = new Set();
        return {
          addListener: (listener) => { listeners.add(listener); },
          removeListener: (listener) => { listeners.delete(listener); },
          hasListener: (listener) => listeners.has(listener),
        };
      };
      for (const name of ['onUpdateAvailable', 'onRestartRequired', 'onSuspend', 'onSuspendCanceled']) {
        add(api.runtime, name, event());
      }
      add(api.runtime, 'requestUpdateCheck', async (callback) => {
        const result = { status: 'no_update' };
        if (callback) callback(result.status, {});
        return result;
      });
      add(api.runtime, 'getContexts', async () => []);
      add(api, 'offscreen', {
        hasDocument: async () => false,
        createDocument: async () => { throw new Error('Offscreen documents are not available.'); },
        closeDocument: async () => {},
      });
    })();
    """

    public struct Prepared: Sendable {
        /// Where to run the extension from.
        public let folder: URL
        /// WebKit keeps a worker's scripts and reuses them whatever's on disk, and an update to one
        /// it already has crashes its web process, so a changed worker has to be forgotten first.
        public let workerChanged: Bool
    }

    /// `folder` itself if the extension needs nothing, or a fresh copy in `root`.
    public static func prepare(_ folder: URL, id: String, in root: URL) throws -> Prepared {
        let file = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: file),
              var manifest = (try? JSONSerialization.jsonObject(with: ExtensionManifest.withoutComments(data))) as? [String: Any],
              var background = manifest["background"] as? [String: Any],
              let worker = background["service_worker"] as? String
        else { return Prepared(folder: folder, workerChanged: false) }

        let copy = root.appending(path: id, directoryHint: .isDirectory)
        let files = FileManager.default
        try? files.removeItem(at: copy)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try files.copyItem(at: folder, to: copy)

        // Rooted paths, because a relative one would be read against the wrapper's own place.
        let path = "/" + worker.split(separator: "/").joined(separator: "/")
        let wrapper = background["type"] as? String == "module"
            ? "import \"/\(compatibilityFile)\";\nimport \"\(path)\";\n"
            : "importScripts(\"/\(compatibilityFile)\", \"\(path)\");\n"
        try Data(compatibility.utf8).write(to: copy.appending(path: compatibilityFile))
        try Data(wrapper.utf8).write(to: copy.appending(path: workerFile))

        background["service_worker"] = workerFile
        manifest["background"] = background
        if let scripts = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = scripts.map(loadingCompatibility)
        }
        try addCompatibility(toPagesIn: copy)
        try JSONSerialization.data(withJSONObject: manifest).write(to: copy.appending(path: "manifest.json"))

        var hash = SHA256()
        hash.update(data: data)
        hash.update(data: Data(compatibility.utf8))
        hash.update(data: Data(wrapper.utf8))
        hash.update(data: (try? Data(contentsOf: folder.appending(path: worker))) ?? Data())
        let digest = Data(hash.finalize())
        let record = workerRecord(id: id, in: root)
        let changed = (try? Data(contentsOf: record)) != digest
        try digest.write(to: record)
        return Prepared(folder: copy, workerChanged: changed)
    }

    /// A page's own world never runs extension APIs, so main world scripts are left alone.
    private static func loadingCompatibility(_ entry: [String: Any]) -> [String: Any] {
        guard let scripts = entry["js"] as? [String], !scripts.isEmpty, entry["world"] as? String != "MAIN" else { return entry }
        var entry = entry
        entry["js"] = [compatibilityFile] + scripts
        return entry
    }

    private static func addCompatibility(toPagesIn folder: URL) throws {
        let tag = "<script src=\"/\(compatibilityFile)\"></script>"
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where ["html", "htm"].contains(file.pathExtension.lowercased()) {
            guard let page = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard let script = page.range(of: "<script", options: .caseInsensitive) else { continue }
            try (page[..<script.lowerBound] + tag + page[script.lowerBound...]).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func workerRecord(id: String, in root: URL) -> URL {
        root.appending(path: id + ".worker")
    }

    /// Removes a copy made by `prepare`, if there is one.
    public static func discard(id: String, in root: URL) {
        try? FileManager.default.removeItem(at: root.appending(path: id, directoryHint: .isDirectory))
        try? FileManager.default.removeItem(at: workerRecord(id: id, in: root))
    }
}
