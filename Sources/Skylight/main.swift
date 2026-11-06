import AppKit
import SkylightCore

// AppKit otherwise swallows Objective-C exceptions and carries on. One that passes through a Swift
// task leaves the concurrency runtime corrupt, and the app dies much later somewhere unrelated.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
let app = NSApplication.shared
let info = Bundle.main.infoDictionary ?? [:]
let environment = AppPaths.launchEnvironment(ProcessInfo.processInfo.environment,
                                             published: info["SkylightPublished"] as? Bool ?? false)
// SKYLIGHT_DATA_DIR keeps a development run away from your real tabs.
let paths = environment["SKYLIGHT_DATA_DIR"]
    .map { AppPaths(root: URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath()) }
    ?? AppPaths.standard()
let demo = environment["SKYLIGHT_DEV"] != nil
let devBuild = demo || (info["SkylightDevBuild"] as? Bool ?? false)
let delegate = AppDelegate(paths: paths, demo: demo, development: devBuild)
app.delegate = delegate
app.run()
