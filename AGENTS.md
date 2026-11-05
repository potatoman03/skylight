# Working on Skylight

Notes for anyone changing the code, coding agents included: how the modules fit together, where a
change goes, what must stay true, and how to check your work. Building and running are in
[README.md](README.md). Branches, commits and pull requests are in
[CONTRIBUTING.md](CONTRIBUTING.md). Known boundary problems are in
[docs/architecture.md](docs/architecture.md).

## Module map

Each module is a target in `Package.swift`. Arrows point at dependencies, and they only go one way:

```
Skylight (app) ─┬─> SkylightUI ──> SkylightBrowser ─┬─> SkylightCore
                │                                   ├─> SkylightEngine ──> SkylightCore
                │                                   ├─> SkylightKit ─────> SkylightCore
                │                                   ├─> SkylightAgent ───> SkylightCore
                │                                   └─> SkylightMCP ─────> SkylightAgent, SkylightCore
                └─> SkylightCEF ──> SkylightEngine, SkylightCore
                         └─> CEFBridge (Objective-C++) ──> libcef_dll_wrapper (Vendor/cef)
SkylightHelper ──> CEFBridge
```

| Module | Owns | May import |
|---|---|---|
| `SkylightCore` | `BrowserState`, `BrowserAction`, `BrowserReducer`, `BrowserEffect`, `BrowserStore`, models, persistence (`AppPaths`, `StateStore`), themes, splits, omnibox parsing, Tidy, Arc/bookmark importers, `JSONValue` | Foundation, CoreGraphics (geometry), Observation |
| `SkylightEngine` | `WebEngine`, `WebPage`, `WebProfile`, `ExtensionHost`, `WebPageDelegate`, `PageEvent`, `PermissionRequest`, `DialogRequest` | Core, AppKit (only for `NSView`) |
| `SkylightKit` | Packages (manifest, loader, URL match patterns, script composition, directory watching), Chrome extension manifests, native messaging hosts, passwords (`CredentialStore`, Keychain, CSV, Chromium import) | Core, Foundation, Security, SQLite3 |
| `SkylightAgent` | `ToolHub`, `AgentTool`, `ToolDefinition`, approvals, agent page scripts, WebMCP | Core |
| `SkylightMCP` | The MCP server: HTTP on `127.0.0.1`, JSON-RPC handling, `mcp.json` | Core, Agent, Network |
| `SkylightBrowser` | `Browser` (composition root), `PageCoordinator` (effects → engine), services: agents, packages, passwords, extensions, media, prompts, toasts, preferences, Tidy, command bar | Core, Engine, Kit, Agent, MCP, AppKit |
| `SkylightUI` | Every SwiftUI view, the Settings window, menus' shortcut map, the sky shader, drag and drop | Browser, Core, Engine (value types only), Agent, Kit, SwiftUI, AppKit |
| `SkylightCEF` | `CEFEngine`, `CEFPage`, `CEFRuntime`, the extension host and its `chrome.tabs`/`chrome.windows` shim | Core, Engine, CEFBridge |
| `CEFBridge` | Objective-C++ over CEF's C++ API (`SKEngine`, `SKBrowser`, `SKHelper`) | CEF |
| `Skylight` | `main.swift` (starts CEF), `AppDelegate` (builds `Browser`, the window and the menu bar) | everything above |
| `SkylightHelper` | Chromium's sub-process executable (renderer, GPU, utility) | CEFBridge |

Rules the map implies:

- **Only `SkylightCEF` and `CEFBridge` know about Chromium.** No other module imports them, and
  no CEF type or name appears outside them. Everything else talks to `WebEngine` and `WebPage`.
- **`SkylightCore` is pure.** No AppKit, no SwiftUI, no engine. It reads and writes files only
  through `StateStore`; importers take `Data`, and the caller reads the file. It's where most
  tests live.
- **`SkylightUI` doesn't call the engine.** It shows `WebPage.view` through `PageCoordinator`'s
  host view and reads engine value types (`PermissionRequest`), but it never calls `WebPage`
  methods or creates pages. Ask `Browser` or send an action instead.
- **Behavior lives in `SkylightBrowser`, not in views.** If the app target or a menu item needs it,
  it goes on `Browser` or a service, not in an `extension Browser` inside SkylightUI.
- **Declare what you import.** If a target imports a module, list it in that target's
  `dependencies` in `Package.swift`, even when it would build transitively.

## Where each kind of change goes

| Change | Where |
|---|---|
| Something the user can do to tabs, Spaces, folders, splits, favorites | A `BrowserAction` case, handled in `BrowserReducer` (pure), plus a test in `Tests/SkylightCoreTests`. If it needs the engine, return a `BrowserEffect`; `PageCoordinator` performs it. |
| Something saved across launches | `BrowserState` (in `state.json`) or `Preferences` (in `preferences.json`). Keep old files decoding: new fields need defaults. |
| Talking to web pages: load, script, events | `WebEngine`/`WebPage` in SkylightEngine first, then `CEFPage`/`CEFEngine`, then `CEFBridge` if CEF's C++ API is needed. |
| A new Chromium switch or CEF setting | `CEFBridge/SKEngine.mm`. Append to switches like `disable-features`; never overwrite CEF's own values. |
| A page script every page gets | `WebEngine.setPageScripts`, assembled by `Browser`. Page scripts reach Skylight only through `window.__skylight.post`. |
| Packages and boosts | `SkylightKit` (manifest, matching, scripts), `PackageService` in SkylightBrowser. |
| Chrome extensions | Manifest parsing in `SkylightKit/Extensions`. Install, update and the store in `ExtensionService`. The tabs/windows shim in `SkylightCEF/CEFExtensions.swift`. UI in `SkylightUI/Extensions.swift`. |
| Passwords | Storage and importers in `SkylightKit/Passwords`, flows (fill, save offer, Touch ID) in `PasswordService`, UI in `SkylightUI/Passwords.swift`. |
| An agent tool | `AgentService.builtInTools()` in SkylightBrowser, registered on `ToolHub`. Mark anything that changes something as a write, so the user gets an approval alert. Test the protocol side in `Tests/SkylightMCPTests`. |
| MCP transport, auth, origin checks | `SkylightMCP`. |
| A prompt (permission, dialog, approval) | A `Prompt` case in `PromptCenter`, shown by the alert host in `ContentArea.swift`. |
| A view, Settings page, sidebar row, toolbar item | `SkylightUI`. Motion tokens are in `Motion.swift`, colors in `Theme.swift`. |
| A menu item or keyboard shortcut | `Sources/Skylight/MainMenu.swift` (the action is an `@objc` method on `AppDelegate`). The shortcuts sheet reads the menu bar, so it picks the item up. |
| Build, bundle, signing | `scripts/bundle.sh`. CEF version: `scripts/fetch-cef.sh`. |

## Invariants and gotchas

- **Pages are AppKit views, and SwiftUI doesn't animate them.** A page is an `NSView` that
  `PageCoordinator` puts in its host view. SwiftUI never re-creates it, so pages keep running. It
  moves and resizes at once, outside any `withAnimation`. Anything drawn over a page (dividers,
  grips, drop previews) must follow its frame without animating, or it drifts from the page. To
  change how panes arrive, use the coordinator's `CATransition` crossfade, not a SwiftUI
  transition.
- **Tabs are not pages.** A tab is a saved place in `BrowserState`. A page exists only while its
  tab is awake (`PageCoordinator.pages`) and is put to sleep by `HibernationPolicy`. Code that
  needs a page must handle there being none (`page(for:)` returns nil). Use `wake(_:)` only if the
  user asked for the tab.
- **One source of truth.** Every change goes through `BrowserStore.send(_:)`. The reducer never
  touches the engine, the clock or the disk directly: `ReducerEnvironment` supplies time and ids,
  so tests are deterministic.
- **Hardened-runtime signing goes inside out** (`bundle.sh`, the signed branch): first each
  `.dylib` in `Chromium Embedded Framework.framework/Libraries`, then the framework, then the five
  helpers (Renderer and GPU with `allow-jit`, the rest with none), then the app with its
  entitlements. Signing the framework doesn't re-sign its libraries, and the hardened runtime
  refuses code signed by another team, so skipping or reordering a step gives an app that won't
  start its helpers. Helper names (`Skylight Helper (Renderer).app` and the others) are what
  Chromium looks for. Don't rename them.
- **Dev mode keeps the mock keychain.** An ad hoc build (`SkylightDevBuild` true) or
  `SKYLIGHT_DEV=1` passes `use-mock-keychain` to Chromium. Only `SKYLIGHT_DEV=1` also swaps the
  password store for `MemoryCredentialStore.demo()`. Don't make a development run read or write
  the login Keychain, and don't turn the mock keychain off for ad hoc builds: their signature
  changes every build, so macOS would ask for the Keychain at every launch.
- **Tests never touch real profiles, the real Keychain, or real store extensions.** Use temporary
  folders, `InMemoryStateStore` and `MemoryCredentialStore`. Pass folders in (as
  `NativeMessagingHosts.adopt(from:into:)` takes them) rather than reading
  `AppPaths.standard()` or another browser's folders. Parse extension manifests from fixtures,
  never from the Chrome Web Store.
- **Never read or print secrets.** Password fields and card fields stay out of agent reads. When
  debugging the password code, use demo mode, never your own Keychain items. Never commit
  `.signing`.
- **Chromium profile folders sit directly inside `Engine/`** (`Default`, `Profile-<id>`).
  Chromium rejects nested ones. Extensions run only in `Default`.
- **Run against a throwaway data folder.** `SKYLIGHT_DATA_DIR` resolves symlinks because Chromium
  compares cache paths literally (`/var` vs `/private/var`). If Skylight is installed and running,
  `open build/Skylight.app` activates that copy instead (same bundle id). Start the executable
  directly, and quit only the process you started.
- **CEF has to shut down with no pages open.** Quit goes through `Browser.shutdown`, which closes
  every page before `CEFRuntime.quit()`. Don't call `exit` or `NSApp.terminate` around it.
- **Main actor everywhere UI-side.** The store, `Browser`, services and the engine adapters are
  `@MainActor`. CEF callbacks arrive on the main thread and hop in with
  `MainActor.assumeIsolated`.

## Verifying a change

1. `swift build`. It must finish without errors.
2. `swift test`: every test passes (116 at the time of writing). Without CEF, run
   `swift build --product SkylightPackageTests` and then `swift test --skip-build`.
3. For anything that runs in the app: `scripts/bundle.sh`, then
   `SKYLIGHT_DEV=1 SKYLIGHT_DATA_DIR="$(mktemp -d)" build/Skylight.app/Contents/MacOS/Skylight`,
   and try it. Check light and dark mode, and Reduce Motion if it animates.
4. For signing or bundling changes: `codesign --verify --deep --strict build/Skylight.app`.
5. For CI changes: `actionlint .github/workflows/ci.yml`.

Say in the pull request which of these you ran. If you couldn't run one (no CEF, no display),
say that too.
