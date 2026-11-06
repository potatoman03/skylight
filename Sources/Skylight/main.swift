import AppKit
import SkylightBrowser
import SkylightCEF
import SkylightCore
import SkylightKit

// Chromium needs its own NSApplication subclass, created before anything touches NSApp.
let app = CEFRuntime.makeApplication()
let info = Bundle.main.infoDictionary ?? [:]
let environment = AppPaths.launchEnvironment(ProcessInfo.processInfo.environment,
                                             published: info["SkylightPublished"] as? Bool ?? false)
// SKYLIGHT_DATA_DIR keeps a development run away from your real tabs.
// Symlinks are resolved: Chromium compares its cache paths literally (/var vs /private/var).
let paths = environment["SKYLIGHT_DATA_DIR"]
    .map { AppPaths(root: URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath()) }
    ?? AppPaths.standard()
let demo = environment["SKYLIGHT_DEV"] != nil
let devBuild = demo || (info["SkylightDevBuild"] as? Bool ?? false)
let debugPort = Int(environment["SKYLIGHT_DEBUG_PORT"] ?? "") ?? 0
let delegate = AppDelegate(paths: paths, demo: demo, development: devBuild)
app.delegate = delegate

// Password managers and other apps' extensions reach their apps through hosts made for other browsers.
NativeMessagingHosts.adopt(into: paths.engineRoot.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory))

do {
    try CEFRuntime.start(.init(
        cacheRoot: paths.engineRoot,
        logFile: paths.root.appending(path: "engine.log"),
        // Unsigned builds would prompt for the login keychain on every launch.
        useMockKeychain: devBuild,
        remoteDebuggingPort: debugPort,
        defaultProfile: paths.profileDirectory(for: .standard),
        extensionFolders: ExtensionService.launchFolders(root: paths.root),
        extensionHelper: paths.extensionHelper
    )) {
        delegate.engineDidStart()
    }
} catch {
    let alert = NSAlert()
    alert.messageText = "Skylight couldn't start its web engine"
    alert.informativeText = "Run scripts/bundle.sh to build a complete app. (\(error))"
    alert.runModal()
    exit(1)
}

CEFRuntime.runMessageLoop()
delegate.browserWillExit()
CEFRuntime.shutdown()
