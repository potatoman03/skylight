// swift-tools-version: 6.2
import PackageDescription

// Skylight: a native macOS browser, in Swift, on the system's WebKit.
//
// Module graph (arrows point at dependencies):
//
//   Skylight (app) ─┬─> SkylightUI ──> SkylightBrowser ─┬─> SkylightCore
//                   │                                   ├─> SkylightEngine ──> SkylightCore
//                   │                                   ├─> SkylightKit ─────> SkylightCore
//                   │                                   ├─> SkylightAgent ───> SkylightCore
//                   │                                   └─> SkylightMCP ─────> SkylightAgent
//                   └─> SkylightWebKit ──> SkylightEngine, SkylightCore
//
// Only SkylightWebKit knows about WebKit. Everything else talks to the `WebEngine`
// protocol in SkylightEngine.

let package = Package(
    name: "Skylight",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Skylight", targets: ["Skylight"]),
    ],
    dependencies: [
        // Updates: checks the GitHub releases feed and installs new versions.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure model and logic: state, actions, the reducer, the store. Foundation (plus CoreGraphics
        // geometry and Observation) only, fully unit-tested.
        .target(name: "SkylightCore"),

        // Engine-agnostic protocols for web pages, profiles and scripts.
        .target(name: "SkylightEngine", dependencies: ["SkylightCore"]),

        // Things Skylight reads from disk and the system, with no engine or UI: packages and boosts,
        // Chrome extension manifests and native messaging hosts, and passwords (Keychain, CSV,
        // other Chromium browsers).
        .target(name: "SkylightKit", dependencies: ["SkylightCore"]),

        // Agent tools: the tool registry, built-in browser tools, page scripts, WebMCP.
        .target(name: "SkylightAgent", dependencies: ["SkylightCore"]),

        // Model Context Protocol over local HTTP.
        .target(name: "SkylightMCP", dependencies: ["SkylightCore", "SkylightAgent"]),

        // Orchestration: connects the store, the engine, packages and agents.
        .target(
            name: "SkylightBrowser",
            dependencies: ["SkylightCore", "SkylightEngine", "SkylightKit", "SkylightAgent", "SkylightMCP"]
        ),

        // SwiftUI chrome.
        .target(name: "SkylightUI", dependencies: ["SkylightBrowser", "SkylightCore", "SkylightEngine", "SkylightAgent", "SkylightKit"]),

        // Swift adapter that makes the system's WebKit conform to SkylightEngine.
        .target(name: "SkylightWebKit", dependencies: ["SkylightCore", "SkylightEngine"]),

        // The app: builds the engine and the browser and hands the browser to the UI.
        // Only the app knows about Sparkle; bundle.sh puts its framework in Contents/Frameworks.
        .executableTarget(
            name: "Skylight",
            dependencies: ["SkylightUI", "SkylightWebKit", "SkylightBrowser", "SkylightCore", "SkylightEngine", "SkylightKit",
                           .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),

        .testTarget(name: "SkylightCoreTests", dependencies: ["SkylightCore"]),
        .testTarget(name: "SkylightKitTests", dependencies: ["SkylightKit", "SkylightCore"]),
        .testTarget(name: "SkylightMCPTests", dependencies: ["SkylightMCP", "SkylightAgent"]),
    ]
)
