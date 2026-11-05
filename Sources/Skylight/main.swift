import AppKit
import SkylightCEF
import SkylightCore
import SkylightKit

// Chromium needs its own NSApplication subclass, created before anything touches NSApp.
let app = CEFRuntime.makeApplication()
// SKYLIGHT_DATA_DIR keeps a development run away from your real tabs.
// Symlinks are resolved: Chromium compares its cache paths literally (/var vs /private/var).
let paths = ProcessInfo.processInfo.environment["SKYLIGHT_DATA_DIR"]
    .map { AppPaths(root: URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath()) }
    ?? AppPaths.standard()
let delegate = AppDelegate(paths: paths)
app.delegate = delegate

let info = Bundle.main.infoDictionary ?? [:]
let devBuild = ProcessInfo.processInfo.environment["SKYLIGHT_DEV"] != nil || (info["SkylightDevBuild"] as? Bool ?? false)
let debugPort = Int(ProcessInfo.processInfo.environment["SKYLIGHT_DEBUG_PORT"] ?? "") ?? 0
// Password managers and other apps' extensions reach their apps through hosts made for other browsers.
NativeMessagingHosts.adopt(into: paths.engineRoot.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory))

do {
    try CEFRuntime.start(.init(
        cacheRoot: paths.engineRoot,
        logFile: paths.root.appending(path: "engine.log"),
        // Unsigned builds would prompt for the login keychain on every launch.
        useMockKeychain: devBuild,
        remoteDebuggingPort: debugPort,
        defaultProfile: paths.profileDirectory(for: .standard)
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
