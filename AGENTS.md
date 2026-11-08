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
                └─> SkylightWebKit ──> SkylightEngine, SkylightCore
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
| `SkylightWebKit` | `WebKitEngine`, `WebKitPage`, `WebKitProfile`, `WebKitExtensionHost` | Core, Engine, WebKit, AppKit |
| `Skylight` | `main.swift`, `AppDelegate` (builds `Browser`, the window and the menu bar) | everything above |

Rules the map implies:

- **Only `SkylightWebKit` knows about WebKit.** No other module imports it, and no WebKit type
  appears outside it. Everything else talks to `WebEngine` and `WebPage`. WebKit has a `WebPage` of
  its own, so write `SkylightEngine.WebPage` in that module.
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
| Talking to web pages: load, script, events | `WebEngine`/`WebPage` in SkylightEngine first, then `WebKitPage`/`WebKitEngine`. |
| A WebKit setting | `WebKitEngine.configuration(for:url:)`. |
| A page script every page gets | `WebEngine.setPageScripts`, assembled by `Browser`. Page scripts reach Skylight only through `window.__skylight.post`. |
| Packages and boosts | `SkylightKit` (manifest, matching, scripts), `PackageService` in SkylightBrowser. |
| Chrome extensions | Manifest parsing and the compatibility copy in `SkylightKit/Extensions`. Install, update and the store in `ExtensionService`. Running them in `SkylightWebKit/WebKitExtensions.swift`. UI in `SkylightUI/Extensions.swift`. |
| Passwords | Storage and importers in `SkylightKit/Passwords`, flows (fill, save offer, Touch ID) in `PasswordService`, UI in `SkylightUI/Passwords.swift`. |
| Addresses and cards | Storage, the Chromium importer and the fill script in `SkylightKit/Autofill`, flows in `AutofillService`, UI in `SkylightUI/Autofill.swift`. |
| History | `HistoryStore` and the Chromium importer in `SkylightKit/History`, recorded by `Browser`, UI in `SkylightUI/Autofill.swift`. Never give agents a way to read it. |
| An agent tool | `AgentService.builtInTools()` in SkylightBrowser, registered on `ToolHub`. Mark anything that changes something as a write, so the user gets an approval alert. Test the protocol side in `Tests/SkylightMCPTests`. |
| MCP transport, auth, origin checks | `SkylightMCP`. |
| A prompt (permission, dialog, approval) | A `Prompt` case in `PromptCenter`, shown by the alert host in `ContentArea.swift`. |
| A view, Settings page, sidebar row, toolbar item | `SkylightUI`. Motion tokens are in `Motion.swift`, colors in `Theme.swift`. |
| A menu item or keyboard shortcut | `Sources/Skylight/MainMenu.swift` (the action is an `@objc` method on `AppDelegate`). The shortcuts sheet reads the menu bar, so it picks the item up. |
| A row in Skylight's menu (the Space button at the left of the Space bar) | `MenuContent` in `Sources/SkylightUI/SkylightMenu.swift`. Give it a menu bar command where one exists, so its action and shortcut can't drift. |
| Build, bundle, signing | `scripts/bundle.sh`. Releases that installed copies update to: `scripts/publish.sh`. Notarized DMGs: `scripts/release.sh`, which packs them with `scripts/dmg.sh` (its background is drawn by `scripts/dmg-background.swift`). |
| The website | `site/`, plain HTML and CSS with no build step. `.github/workflows/pages.yml` deploys it to GitHub Pages when it changes on `main`. |
| Updates | `Sources/Skylight/Updater.swift` (Sparkle, app target only). The feed URL and public key are in `bundle.sh`. |

## Invariants and gotchas

- **Pages are AppKit views, and SwiftUI doesn't animate them.** A page is an `NSView` that
  `PageCoordinator` puts in its host view. SwiftUI never re-creates it, so pages keep running. It
  moves and resizes at once, outside any `withAnimation`. Anything drawn over a page (dividers,
  grips, drop previews) must follow its frame without animating, or it drifts from the page. To
  change how panes arrive, use the coordinator's `CATransition` crossfade, not a SwiftUI
  transition. The one exception is showing or hiding the sidebar: Core Animation moves the
  visible edge (a mask), and a display link sets the page's frame from the same curve every
  frame. WebKit shows each new width's layout a few frames late, so `RightPin` holds the drawing
  against the view's right edge until it lands, watching WebKit's "overhang areas" layer. A page
  alone also reaches under the sidebar and lays out beside it through `setCovered`, so dragging
  the sidebar's edge never moves its right side. Don't animate `obscuredContentInsets`: WebKit
  holds it back for 70 ms or more and drops widths.
  A theme's picture is an AppKit view too, so anything holding one doesn't fade: the wash over it
  would fade and the picture wouldn't, and it flashes.
- **Tabs are not pages.** A tab is a saved place in `BrowserState`. A page exists only while its
  tab is awake (`PageCoordinator.pages`) and is put to sleep by `HibernationPolicy`. Code that
  needs a page must handle there being none (`page(for:)` returns nil). Use `wake(_:)` only if the
  user asked for the tab. The one exception is after launch, when the three tabs used last come
  back one at a time behind the page on screen (not in Low Power Mode).
- **One source of truth.** Every change goes through `BrowserStore.send(_:)`. The reducer never
  touches the engine, the clock or the disk directly: `ReducerEnvironment` supplies time and ids,
  so tests are deterministic.
- **An Objective-C exception must never pass through a Swift task.** AppKit would catch it at the
  top of the run loop and carry on, but the task's executor record is left dangling, and the app
  dies much later in an unrelated `MainActor.assumeIsolated`. WebKit throws for misuse, such as a
  configuration whose data store differs from its related web view's, so `main.swift` turns on
  `NSApplicationCrashOnExceptions`: the crash lands where the exception was thrown. Don't turn it
  off.
- **Avoid the async `evaluateJavaScript`.** Its Swift form is known to crash when a script returns
  null. Use the completion form, or `callAsyncJavaScript`.
- **Leave delegate completion handlers unannotated.** Don't mark a delegate's completion handler
  `@MainActor`. The method stops matching the protocol, the compiler only warns ("nearly matches"),
  and WebKit never calls it.
- **Only some schemes leave the browser.** `mailto`, `tel`, `facetime` and `sms` open another app
  only from a link the user clicked.
- **Published builds ignore the `SKYLIGHT_` environment switches.** `release.sh` marks them
  (`SkylightPublished`), so nothing that launches one can swap its data or drop the Keychain. Other signed builds still honor the switches, which is how you test them.
- **A page never vouches for itself.** WebMCP tools are always writes, whatever a page says, and
  approval prompts describe a call in Skylight's words (`ToolDefinition.request`), naming the site.
- **Agents stay on the web.** `open_tab` and `navigate` take http and https only. The omnibox's
  other schemes are for people to type.
- **An extension update can't gain access quietly.** `addedWarnings(since:)` compares the sites
  themselves, including content scripts, and asks if any are new.
- **Tests never touch real profiles, the real Keychain, or real store extensions.** Use temporary
  folders, `InMemoryStateStore` and `MemoryCredentialStore`. Pass folders in (as
  `NativeMessagingHosts.adopt(from:into:)` takes them) rather than reading
  `AppPaths.standard()` or another browser's folders. Parse extension manifests from fixtures,
  never from the Chrome Web Store.
- **The update key never leaves the keychain.** Sparkle's private key (`generate_keys --account
  skylight`) signs every release; installed copies refuse anything else. Never commit or print
  it, and don't change `SUPublicEDKey` in `bundle.sh` without it, or installed copies stop
  updating.
- **A card only goes where you just sent it.** Filling happens from Skylight's UI, never because a
  page asked. A card takes Touch ID or the Mac's password, goes only to https, and is dropped if the
  tab moved during the prompt. Choosing a fill hands those values to that page: the script skips
  hidden fields, but it runs in the page, so don't treat that as a boundary. Listings hold no card
  numbers; a fill reads one when it's needed.
- **Never read or print secrets.** Password fields and card fields stay out of agent reads. When
  debugging the password code, use demo mode, never your own Keychain items. Never commit
  `.signing`.
- **A profile is a WebKit data store.** WebKit decides where a store lives (`~/Library/WebKit`),
  so a profile's folder in `Engine/` only keeps the store's identifier, in `webkit-store`. Deleting
  a profile has to remove the store as well. The folders are still named `Default` and
  `Profile-<id>`, so sign-ins left by Chromium builds can be found.
- **Web Inspector docks through a private call.** `isInspectable` and `developerExtrasEnabled` give
  Inspect Element; showing and closing it from the menu use `_inspector`, guarded with
  `responds(to:)`, so a future macOS can only take the menu command away.
- **An extension's service worker runs behind a compatibility script.** WebKit leaves out some
  Chrome APIs, and a worker that touches one while it starts never runs (WebKit records
  `WKWebExtensionContextErrorDomain` code 6), which takes the extension with it. Nothing can be
  injected ahead of a worker, so `ExtensionRuntime` copies the extension to `ExtensionRuntime/<id>`
  and points its manifest at a wrapper. Add missing APIs there. The installed folder is never
  changed, so `ExtensionManifest` keeps reading that one. WebKit holds the script wrappers of its
  API objects weakly, so anything added to one must also be kept alive: the script pins
  `chrome.runtime`, and a small test worker won't show it when that's forgotten, because the
  wrapper only goes when a collection runs during startup. It also locks the `chrome` and `browser`
  globals: WebKit delivers events through them, and Proton Pass replaces them, so the copy loads the
  script in the extension's pages and isolated content scripts as well as its worker. WebKit reuses a worker's stored scripts
  whatever's on disk, and changing the worker's address makes it update one in place, which crashes
  its web process on every try. So the address stays put, and `ExtensionService` forgets stored
  workers when `ExtensionRuntime` reports a change.
- WebKit silently drops what a content script sends from a tab it doesn't know, so `makePage` opens
  the tab with `WebKitExtensionHost.open` before the page starts loading.
- **Extensions expect all of Chrome.** WebKit leaves out `notifications`, `privacy`, `idle`,
  `management`, `downloads` and more, and `requestIdleCallback` in pages. Password managers read
  them at startup and catch their own errors, so a gap looks like nothing happening. The
  compatibility script stands in for them; what an extension can only want done refuses rather
  than pretending. WebKit's own log says when a call fails:
  `log show --last 5m --predicate 'category == "Extensions"'`.
- **A popup's viewport follows its frame.** WebKit's popup web view lays out at its content's size
  and ignores the frame, so a popup that copies its viewport into its own size (Proton Pass does)
  gets stuck at whatever it saw first. `presentActionPopup` turns that mode off with a guarded
  private call, and `measure` ignores custom properties set on the root, because that's where
  those popups write the size back.
- **Every profile runs every extension.** A profile has one `WKWebExtensionController`, and an
  extension gets a context in each. Each context has a set `baseURL`, so its address and storage
  stay the same between launches. An extension's own pages use the context's configuration
  unchanged: they're related to its background page, and WKWebView throws if the data store
  differs.
- **Sessions move once.** Cookies from older Chromium builds of Skylight are read by
  `ChromiumCookieImporter` and moved by `Browser.moveChromiumSessions`, guarded by
  `preferences.movedChromiumSessions`.
- **Keychain items for a profile differ in two attributes on purpose.** The description is how
  Skylight finds them, and the default profile's never changes, so older passwords stay with it.
  Other profiles also set a security domain, because the description isn't part of what makes a
  Keychain item unique and the same login may be saved in two profiles.
- **Fill a new profile before anything opens it.** Cookies go through the data store's cookie store,
  because httpOnly cookies are out of a page's reach. WebKit keeps extension storage to itself, so a
  new Space's extensions start fresh. Read cookie names to see who's signed in, never their values;
  only an import handles a value, passing it straight to the profile, and never logs it. A profile
  with `passwordsFrom` stores no passwords of its own, so anything reading or saving them goes
  through `BrowserState.passwordProfile(for:)`.
- **Run against a throwaway data folder.** If Skylight is installed and running, `open
  build/Skylight.app` activates that copy instead (same bundle id). Start the executable directly,
  and quit only the process you started. WebKit's network process ignores `CFFIXED_USER_HOME`, so
  a test run's stores always land in the real `~/Library/WebKit`. Keep test data made up.
- **The welcome's picture flows only in the opening.** `FlowingPicture` (Metal, on a
  `CAMetalDisplayLink`, so the main thread never waits for a drawable) moves the theme picture
  while the name arrives, comes to rest, and is then removed; later steps show the still picture.
  Keep it that way, and keep it off with Reduce Motion. The opening's sound (`OpeningSound`) is
  synthesized and respects the Mac's interface sound setting.
- **Main actor everywhere UI-side.** The store, `Browser`, services and the engine adapters are
  `@MainActor`. Timers and notification observers hop in with `MainActor.assumeIsolated`.

## Verifying a change

1. `swift build`. It must finish without errors.
2. `swift test`: every test passes (276 at the time of writing).
3. For anything that runs in the app: `scripts/bundle.sh`, then
   `SKYLIGHT_DEV=1 SKYLIGHT_DATA_DIR="$(mktemp -d)" build/Skylight.app/Contents/MacOS/Skylight`,
   and try it. Check light and dark mode, and Reduce Motion if it animates.
4. For signing or bundling changes: `codesign --verify --deep --strict build/Skylight.app`.
5. For CI changes: `actionlint .github/workflows/ci.yml`.

Say in the pull request which of these you ran. If you couldn't run one (no display), say that
too.
