import AppKit
import SkylightCEF
import SkylightCore

// Chromium needs its own NSApplication subclass, created before anything touches NSApp.
let app = CEFRuntime.makeApplication()
let paths = AppPaths.standard()
let delegate = AppDelegate(paths: paths)
app.delegate = delegate

let info = Bundle.main.infoDictionary ?? [:]
let devBuild = ProcessInfo.processInfo.environment["SKYLIGHT_DEV"] != nil || (info["SkylightDevBuild"] as? Bool ?? false)
let debugPort = Int(ProcessInfo.processInfo.environment["SKYLIGHT_DEBUG_PORT"] ?? "") ?? 0

do {
    try CEFRuntime.start(.init(
        cacheRoot: paths.engineRoot,
        logFile: paths.root.appending(path: "engine.log"),
        // Unsigned builds would prompt for the login keychain on every launch.
        useMockKeychain: devBuild,
        remoteDebuggingPort: debugPort
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
