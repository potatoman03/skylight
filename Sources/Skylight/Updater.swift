import AppKit
import SkylightBrowser
import Sparkle

/// New versions from the project's GitHub releases, through Sparkle. It reads the feed named by
/// `SUFeedURL` in Info.plist every few hours and downloads new versions quietly
/// (`SUAutomaticallyUpdate`); only builds signed with the release key (`SUPublicEDKey`) are taken.
/// A downloaded update shows as a card in the sidebar, whose Restart installs it and relaunches
/// through the normal quit, so CEF shuts down cleanly. If you never restart, it installs when you
/// next quit. Development builds never update: the last release would replace them.
@MainActor
final class Updater: NSObject {
    private var controller: SPUStandardUpdaterController?
    private weak var browser: Browser?

    init(development: Bool, browser: Browser) {
        self.browser = browser
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil, !development else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

extension Updater: SPUUpdaterDelegate {
    /// Downloaded in the background: keep it for a restart, and offer one in the sidebar.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        browser?.readyUpdate = ReadyUpdate(version: item.displayVersionString, install: immediateInstallationBlock)
        return true
    }
}
