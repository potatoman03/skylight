import Foundation

/// What another Chromium browser has installed.
public enum ChromiumExtensions {
    /// The extensions a profile has switched on from the store, from its `Secure Preferences` and
    /// `Preferences` files. What came with the browser or was installed by hand stays behind, and
    /// so does anything turned off: importing shouldn't turn it on.
    public static func storeIDs(in files: [Data]) -> [String] { ids(in: files, on: true) }

    /// The store extensions a profile has but keeps turned off.
    public static func turnedOffIDs(in files: [Data]) -> [String] { ids(in: files, on: false) }

    private static func ids(in files: [Data], on: Bool) -> [String] {
        var ids: [String] = []
        for file in files {
            guard let root = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
                  let extensions = root["extensions"] as? [String: Any],
                  let settings = extensions["settings"] as? [String: Any] else { continue }
            for (id, value) in settings.sorted(by: { $0.key < $1.key }) {
                guard ExtensionID.isValid(id), !ids.contains(id), let entry = value as? [String: Any],
                      isFromStore(entry), isOn(entry) == on else { continue }
                ids.append(id)
            }
        }
        return ids
    }

    private static func isFromStore(_ entry: [String: Any]) -> Bool {
        // Location 1 is Chromium's "internal": installed from the store, not built in or by policy.
        entry["location"] as? Int == 1 && entry["from_webstore"] as? Bool != false
            && entry["was_installed_by_default"] as? Bool != true && entry["was_installed_by_oem"] as? Bool != true
    }

    private static func isOn(_ entry: [String: Any]) -> Bool {
        guard entry["state"] as? Int != 0 else { return false }
        // Older profiles keep a number here, newer ones a list.
        switch entry["disable_reasons"] {
        case let reasons as Int: return reasons == 0
        case let reasons as [Any]: return reasons.isEmpty
        default: return true
        }
    }
}
