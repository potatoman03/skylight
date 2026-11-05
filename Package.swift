// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Skylight: a native macOS browser shell around Chromium (CEF).
//
// Module graph (arrows point at dependencies):
//
//   Skylight (app) ─┬─> SkylightUI ──> SkylightBrowser ─┬─> SkylightCore
//                   │                                   ├─> SkylightEngine ──> SkylightCore
//                   │                                   ├─> SkylightKit ─────> SkylightCore
//                   │                                   ├─> SkylightAgent ───> SkylightCore
//                   │                                   └─> SkylightMCP ─────> SkylightAgent
//                   └─> SkylightCEF ──> CEFBridge (Objective-C++) ──> libcef_dll_wrapper
//
//   SkylightHelper: the Chromium sub-process executable (renderer, GPU, utility).
//
// Only SkylightCEF and CEFBridge know about Chromium. Everything else talks to the
// `WebEngine` protocol in SkylightEngine, so the engine can be swapped (for example
// for a self-built, debloated CEF) without touching the app.

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let cefRoot = "\(root)/Vendor/cef"
let cefWrapperLib = "\(cefRoot)/build/libcef_dll_wrapper"

let package = Package(
    name: "Skylight",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Skylight", targets: ["Skylight"]),
        .executable(name: "SkylightHelper", targets: ["SkylightHelper"]),
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

        // Objective-C++ bridge over the CEF C++ API.
        .target(
            name: "CEFBridge",
            cxxSettings: [
                // Match libcef_dll_wrapper's build flags.
                .unsafeFlags(["-I", cefRoot, "-fobjc-arc", "-fno-rtti", "-fno-exceptions", "-Wno-deprecated-declarations"]),
                .define("NDEBUG"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", cefWrapperLib]),
                .linkedLibrary("cef_dll_wrapper"),
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
            ]
        ),

        // Swift adapter that makes CEF conform to SkylightEngine.
        .target(name: "SkylightCEF", dependencies: ["SkylightCore", "SkylightEngine", "CEFBridge"]),

        // The app: builds the engine and the browser and hands the browser to the UI.
        // Only the app knows about Sparkle; bundle.sh puts its framework in Contents/Frameworks.
        .executableTarget(
            name: "Skylight",
            dependencies: ["SkylightUI", "SkylightCEF", "SkylightBrowser", "SkylightCore", "SkylightKit",
                           .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "SkylightHelper", dependencies: ["CEFBridge"]),

        .testTarget(name: "SkylightCoreTests", dependencies: ["SkylightCore"]),
        .testTarget(name: "SkylightKitTests", dependencies: ["SkylightKit"]),
        .testTarget(name: "SkylightMCPTests", dependencies: ["SkylightMCP", "SkylightAgent"]),
    ],
    cxxLanguageStandard: .cxx20
)
