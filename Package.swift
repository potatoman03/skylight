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
    targets: [
        // Pure model and logic. Foundation only, fully unit-tested.
        .target(name: "SkylightCore"),

        // Engine-agnostic protocols for web pages, profiles and scripts.
        .target(name: "SkylightEngine", dependencies: ["SkylightCore"]),

        // Packages and boosts: manifests, loading, URL matching, script composition.
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
        .target(name: "SkylightCEF", dependencies: ["SkylightEngine", "CEFBridge"]),

        .executableTarget(name: "Skylight", dependencies: ["SkylightUI", "SkylightCEF"]),
        .executableTarget(name: "SkylightHelper", dependencies: ["CEFBridge"]),

        .testTarget(name: "SkylightCoreTests", dependencies: ["SkylightCore"]),
        .testTarget(name: "SkylightKitTests", dependencies: ["SkylightKit"]),
        .testTarget(name: "SkylightMCPTests", dependencies: ["SkylightMCP", "SkylightAgent"]),
    ],
    cxxLanguageStandard: .cxx20
)
