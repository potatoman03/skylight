import AppKit
import LocalAuthentication
import Observation
import SkylightCore
import SkylightEngine
import SkylightKit
import UniformTypeIdentifiers

/// Saves and fills passwords. They live in the Keychain; the page never sees one until you pick it.
/// Each profile has its own: a Space only offers the logins saved in its profile.
///
/// A small page script reports login fields and submitted logins. Filling only happens when you
/// choose a login in Skylight's own UI, and only into the page whose address matches the login.
@MainActor
@Observable
public final class PasswordService {
    /// A login the page just submitted that isn't saved yet.
    public struct Offer: Identifiable, Equatable {
        public let id = UUID()
        public let tabID: TabID
        public let credential: Credential
        /// A login for this site and username is saved with a different password.
        public let isUpdate: Bool
    }

    /// Every saved login in every profile, without passwords.
    public private(set) var saved: [Credential] = []
    /// Tabs whose page has a password field.
    public private(set) var tabsWithLoginForm: Set<TabID> = []
    public private(set) var offer: Offer?
    public private(set) var lastError: String?

    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let neverFile: URL?
    @ObservationIgnored private var never: Set<String> = []
    /// The profiles to list logins for.
    @ObservationIgnored var profiles: () -> [ProfileID] = { [.standard] }

    public init(store: CredentialStore, toasts: ToastCenter, neverFile: URL?) {
        self.store = store
        self.toasts = toasts
        self.neverFile = neverFile
        if let neverFile, let data = try? Data(contentsOf: neverFile),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            never = Set(list)
        }
        reload()
    }

    public func reload() {
        do {
            saved = try profiles().flatMap { try store.all(in: $0) }
                .sorted { ($0.displayHost, $0.username) < ($1.displayHost, $1.username) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func logins(in profile: ProfileID) -> [Credential] {
        saved.filter { $0.profile == profile }
    }

    /// A profile's logins for the page at `url`.
    public func logins(for url: URL?, in profile: ProfileID) -> [Credential] {
        guard let url, let origin = CredentialOrigin.normalize(url) else { return [] }
        return logins(in: profile).filter { $0.origin == origin }
    }

    // MARK: - Pages

    public static let pageScript = """
    (() => {
      if (window.__skylightPasswords || window.top !== window) return;
      const post = (m) => window.__skylight && window.__skylight.post(m).catch(() => {});
      let reported = false;
      const scan = () => {
        if (!reported && document.querySelector('input[type=password]')) { reported = true; post({ type: 'passwords.form' }); }
      };
      const visible = (el) => el && !el.disabled && el.offsetParent !== null;
      const userField = (pw) => {
        const scope = pw.form || document;
        const inputs = [...scope.querySelectorAll('input')];
        const before = inputs.slice(0, inputs.indexOf(pw)).reverse();
        return before.find((i) => visible(i) && /^(email|text|tel)$/.test(i.type) && i.value)
          || [...document.querySelectorAll('input[autocomplete=username], input[type=email]')].find((i) => i.value);
      };
      let last = '';
      const capture = (scope) => {
        const pw = [...(scope || document).querySelectorAll('input[type=password]')].find((i) => i.value);
        if (!pw) return;
        const user = userField(pw);
        const key = (user ? user.value : '') + '\\u0000' + pw.value;
        if (key === last) return;
        last = key;
        post({ type: 'passwords.submit', username: user ? user.value : '', password: pw.value });
      };
      document.addEventListener('submit', (e) => capture(e.target), true);
      document.addEventListener('click', (e) => {
        const button = e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
        if (button) setTimeout(() => capture(button.form || button.closest('form')), 0);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target.type === 'password') capture(e.target.form);
      }, true);
      new MutationObserver(scan).observe(document, { childList: true, subtree: true });
      document.addEventListener('DOMContentLoaded', scan);
      const setValue = (el, value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      Object.defineProperty(window, '__skylightPasswords', { value: Object.freeze({
        fill(origin, username, password) {
          if (location.origin !== origin) return false;
          const pw = [...document.querySelectorAll('input[type=password]')].find(visible)
            || document.querySelector('input[type=password]');
          const scope = (pw && pw.form) || document;
          const inputs = [...scope.querySelectorAll('input')];
          const user = (pw ? inputs.slice(0, inputs.indexOf(pw)).reverse() : inputs)
            .find((i) => visible(i) && /^(email|text|tel)$/.test(i.type))
            || document.querySelector('input[autocomplete=username], input[type=email]');
          if (user && username) setValue(user, username);
          if (pw) setValue(pw, password);
          last = (username || '') + '\\u0000' + password;
          return Boolean(pw || user);
        },
      }) });
    })();
    """

    /// Handles `passwords.*` messages. `url` is the tab's address as Skylight knows it, never the page's word.
    public func handle(_ message: JSONValue, tab: TabID, url: URL?, profile: ProfileID) -> JSONValue {
        switch message["type"]?.stringValue {
        case "passwords.form":
            tabsWithLoginForm.insert(tab)
        case "passwords.submit":
            guard let url, let origin = CredentialOrigin.normalize(url), !never.contains(origin),
                  let password = message["password"]?.stringValue, !password.isEmpty else { break }
            let username = message["username"]?.stringValue ?? ""
            let existing = logins(in: profile).first { $0.origin == origin && $0.username == username }
            if let existing, (try? store.password(for: existing)) == password { break }
            offer = Offer(tabID: tab, credential: Credential(origin: origin, username: username, password: password, source: "Skylight",
                                                             profile: profile),
                          isUpdate: existing != nil)
        default:
            break
        }
        return .null
    }

    public func pageWentAway(_ tab: TabID) {
        tabsWithLoginForm.remove(tab)
        if offer?.tabID == tab { offer = nil }
    }

    public func acceptOffer() {
        guard let offer else { return }
        self.offer = nil
        do {
            try store.save(offer.credential)
            reload()
            toasts.show(offer.isUpdate ? "Updated the password for \(offer.credential.displayHost)"
                        : "Saved the password for \(offer.credential.displayHost)", symbol: "key.fill")
        } catch {
            toasts.show("Couldn't save the password: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    public func dismissOffer(never site: Bool = false) {
        guard let offer else { return }
        self.offer = nil
        if site {
            never.insert(offer.credential.origin)
            saveNever()
        }
    }

    /// Types a saved login into `page`, if the page is still on the login's site.
    public func fill(_ credential: Credential, in page: WebPage, url: URL?) {
        guard let url, CredentialOrigin.normalize(url) == credential.origin else {
            return toasts.show("That login is for \(credential.displayHost)", symbol: "exclamationmark.triangle")
        }
        do {
            let password = try store.password(for: credential)
            let call = "(window.__skylightPasswords ? window.__skylightPasswords.fill(\(JSONValue.jsLiteral(credential.origin)), "
                + "\(JSONValue.jsLiteral(credential.username)), \(JSONValue.jsLiteral(password))) : false)"
            Task { [toasts] in
                let filled = (try? await page.evaluate(call))?.boolValue ?? false
                if !filled { toasts.show("No login form on this page", symbol: "key") }
            }
        } catch {
            toasts.show("Couldn't read the password: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    // MARK: - Managing

    /// Asks for Touch ID or the Mac's password before showing or exporting passwords.
    public func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    public func copyPassword(_ credential: Credential) async {
        guard await authenticate("copy the password for \(credential.displayHost)") else { return }
        do {
            let password = try store.password(for: credential)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
            toasts.show("Copied the password for \(credential.displayHost)", symbol: "doc.on.clipboard")
        } catch {
            toasts.show("Couldn't read the password: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    public func delete(_ credential: Credential) {
        do {
            try store.delete(credential)
            reload()
        } catch {
            toasts.show("Couldn't delete: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    /// A deleted profile's logins join the default profile's. One you already have there keeps
    /// its password.
    public func moveLogins(from profile: ProfileID) {
        let have = Set(logins(in: .standard).map(\.id))
        var failed = 0
        for login in logins(in: profile) {
            var moved = login
            moved.profile = .standard
            do {
                if !have.contains(moved.id) {
                    moved.password = try store.password(for: login)
                    try store.save(moved)
                }
                try store.delete(login)
            } catch {
                failed += 1
            }
        }
        reload()
        if failed > 0 { toasts.show("Couldn't move \(failed) password\(failed == 1 ? "" : "s") to Default", symbol: "exclamationmark.triangle") }
    }

    /// Imports logins from another browser on this Mac. macOS asks you to let Skylight read that
    /// browser's key from the Keychain.
    public func importFrom(_ browser: ChromiumBrowser, into profile: ProfileID) async -> String {
        let result = await Task.detached { Result { try ChromiumPasswordImporter.read(browser) } }.value
        switch result {
        case let .success(credentials): return add(credentials, from: browser.name, into: profile)
        case let .failure(error): return report(error, from: browser.name)
        }
    }

    /// The saved logins and cookies of a browser's profiles, read together so macOS asks only once.
    /// Demo mode's store is in memory, and a development run stays out of the login Keychain.
    func signIns(from profiles: [ChromiumBrowser]) async throws -> [ChromiumSignIns] {
        if store is MemoryCredentialStore { return profiles.map { _ in ChromiumSignIns() } }
        return try await Task.detached { try ChromiumPasswordImporter.readSignIns(profiles) }.value
    }

    /// Imports a CSV export from Chrome, Safari, 1Password, Bitwarden and the like.
    public func importCSV(into profile: ProfileID) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a passwords CSV exported from another browser or password manager."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return add(try PasswordCSV.parse(text, source: "CSV"), from: url.lastPathComponent, into: profile)
        } catch {
            return report(error, from: url.lastPathComponent)
        }
    }

    /// Writes a profile's passwords to a CSV file you choose, after you authenticate.
    public func exportCSV(_ profile: ProfileID) async {
        guard await authenticate("export your saved passwords") else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Skylight Passwords.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let full = try logins(in: profile).map { c -> Credential in
                var c = c
                c.password = try store.password(for: c)
                return c
            }
            try PasswordCSV.export(full).write(to: url, atomically: true, encoding: .utf8)
            toasts.show("Exported \(full.count) passwords. Delete the file once you're done with it.", symbol: "square.and.arrow.up")
        } catch {
            toasts.show("Couldn't export: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    /// Adds logins you don't have yet; ones you already saved keep their password.
    @discardableResult
    public func add(_ credentials: [Credential], from source: String, into profile: ProfileID) -> String {
        let (added, failed) = save(credentials, into: profile)
        let message = added == 0 && failed == 0 ? "Every password from \(source) is already here"
            : "Imported \(added) password\(added == 1 ? "" : "s") from \(source)" + (failed > 0 ? " (\(failed) failed)" : "")
        toasts.show(message, symbol: "key.fill")
        return message
    }

    /// Saves the logins that aren't here yet. Returns how many were saved and how many failed.
    @discardableResult
    func save(_ credentials: [Credential], into profile: ProfileID) -> (added: Int, failed: Int) {
        let credentials = credentials.map { credential -> Credential in
            var credential = credential
            credential.profile = profile
            return credential
        }
        let have = Set(saved.map(\.id))
        var added = 0
        var failed = 0
        for credential in credentials where !have.contains(credential.id) {
            do {
                try store.save(credential)
                added += 1
            } catch {
                failed += 1
            }
        }
        reload()
        return (added, failed)
    }

    private func report(_ error: Error, from source: String) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't import passwords from \(source)."
        toasts.show(message, symbol: "exclamationmark.triangle")
        return message
    }

    private func saveNever() {
        guard let neverFile else { return }
        try? JSONEncoder().encode(never.sorted()).write(to: neverFile, options: .atomic)
    }
}
