import Foundation
import SkylightCore

/// Turns loaded packages into page scripts. Each package becomes its own script, so a syntax
/// error in one package can't stop the others.
public enum PackageScripts {
    /// The shared runtime that package scripts register with. Runs first.
    public static let runtime = """
    (() => {
      if (window.__skylightPackages) return;
      const commands = new Map();
      const styles = new Map();
      const whenRoot = (fn) => {
        if (document.documentElement) return fn();
        const observer = new MutationObserver(() => {
          if (document.documentElement) { observer.disconnect(); fn(); }
        });
        observer.observe(document, { childList: true });
      };
      const setStyle = (id, css) => {
        let el = styles.get(id);
        if (!el) {
          el = document.createElement('style');
          el.dataset.skylightPackage = id;
          styles.set(id, el);
          whenRoot(() => (document.head || document.documentElement).appendChild(el));
        }
        el.textContent = css;
      };
      const api = Object.freeze({
        define(manifest, patterns, css, body) {
          if (!patterns.some((p) => new RegExp(p, 'i').test(location.href))) return;
          if (css) setStyle(manifest.id, css);
          const skylight = Object.freeze({
            id: manifest.id,
            name: manifest.name,
            command: (name, handler) => commands.set(manifest.id + '/' + name, handler),
            addStyle: (extra) => setStyle(manifest.id + '#' + styles.size, extra),
            onReady: (fn) => document.readyState === 'loading'
              ? document.addEventListener('DOMContentLoaded', fn, { once: true })
              : fn(),
          });
          try { body(skylight); } catch (e) { console.error('[Skylight] package ' + manifest.id + ' failed:', e); }
        },
        async run(packageID, commandID) {
          const handler = commands.get(packageID + '/' + commandID);
          if (!handler) throw new Error('This page has no command ' + commandID + ' from ' + packageID + '.');
          const result = await handler();
          return result === undefined ? null : result;
        },
        updateStyle(id, css) { if (styles.has(id)) setStyle(id, css); },
      });
      Object.defineProperty(window, '__skylightPackages', { value: api, configurable: false, writable: false });
    })();
    """

    public static func scripts(for packages: [LoadedPackage]) -> [String] {
        [runtime] + packages.map(script(for:))
    }

    static func script(for package: LoadedPackage) -> String {
        let manifest: JSONValue = ["id": .string(package.manifest.id), "name": .string(package.manifest.name)]
        let patterns = JSONValue.array(package.matchers.map { .string($0.regexSource) })
        let body = package.scripts.joined(separator: "\n;\n")
        return """
        window.__skylightPackages && window.__skylightPackages.define(\(manifest.serialized()), \(patterns.serialized()), \(JSONValue.jsLiteral(package.css)), function (skylight) {
        \(body)
        });
        """
    }

    /// Expression that runs a package command in the page.
    public static func runCommand(packageID: String, commandID: String) -> String {
        "window.__skylightPackages.run(\(JSONValue.jsLiteral(packageID)), \(JSONValue.jsLiteral(commandID)))"
    }

    /// Expression that swaps a package's CSS in a live page.
    public static func updateStyle(packageID: String, css: String) -> String {
        "(window.__skylightPackages && window.__skylightPackages.updateStyle(\(JSONValue.jsLiteral(packageID)), \(JSONValue.jsLiteral(css))), null)"
    }
}
