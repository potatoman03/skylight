import AppKit
import Sparkle

/// New versions from the project's GitHub releases, through Sparkle. It reads the feed named by
/// `SUFeedURL` in Info.plist about once a day and installs only builds signed with the release key
/// (`SUPublicEDKey`), then relaunches through the normal quit, so CEF shuts down cleanly.
/// Development builds never update: the last release would replace them.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init(development: Bool) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = configured && !development
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
