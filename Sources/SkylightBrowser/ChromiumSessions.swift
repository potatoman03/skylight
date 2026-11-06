import Foundation
import SkylightCore
import SkylightKit

/// Skylight used to run on Chromium, which kept each profile's cookies in its own encrypted file.
/// WebKit can't read that, so once, after the update, the cookies move across and sites stay
/// signed in. Other site data, such as local storage, stays behind.
extension Browser {
    func moveChromiumSessions(from paths: AppPaths) {
        guard !preferences.movedChromiumSessions else { return }
        let profiles = store.state.profiles.map { profile in
            (id: profile.id, browser: ChromiumBrowser(id: "skylight", name: "Skylight",
                                                      profileDirectory: paths.profileDirectory(for: profile.id),
                                                      safeStorageServices: ["Chromium Safe Storage"], bundleIDs: []))
        }.filter { FileManager.default.fileExists(atPath: $0.browser.cookies.path) }
        guard let first = profiles.first else {
            preferences.movedChromiumSessions = true
            return
        }
        Task {
            // Only one attempt: asking at every launch would be worse than signing in again.
            preferences.movedChromiumSessions = true
            let found = await Task.detached { () -> [(ProfileID, [WebCookie])] in
                guard let key = try? ChromiumPasswordImporter.safeStorageKey(for: first.browser) else { return [] }
                return profiles.map { ($0.id, (try? ChromiumCookieImporter.read(cookies: $0.browser.cookies, safeStorageKey: key)) ?? []) }
            }.value
            for (id, cookies) in found { _ = await pages.addCookies(cookies, to: id) }
        }
    }
}
