# Skylight

![Skylight](docs/screenshot.png)

An open-source browser for macOS with Spaces and a vertical sidebar, around Chromium (via CEF). The
shell is stock macOS: a source-list sidebar, one unified toolbar, a Settings window and system
alerts, so it looks and behaves like Safari or Finder. Built to be light, easy to extend, and
usable by AI agents as a first-class citizen.

## Build and run

### Requirements

- macOS 26 on Apple silicon (the CEF build Skylight uses is `macosarm64`).
- Xcode 26 with Swift 6.2 or later (`swift --version`).
- `cmake` and `ninja` for CEF's C++ wrapper: `brew install cmake ninja`. `python3` and `curl`,
  which macOS already has.
- CEF 156 (Chromium 156). You don't install it yourself: the scripts download the exact version
  named in `scripts/fetch-cef.sh` into `Vendor/cef`, which git ignores.

### Fetch CEF, build, run

```bash
scripts/bundle.sh
```

The first run downloads CEF (about 300 MB) into `Vendor/cef` and builds `libcef_dll_wrapper`
(`scripts/fetch-cef.sh`, then `scripts/build-cef-wrapper.sh`; you can run either on its own). Later
runs only rebuild Skylight. The result is `build/Skylight.app`:

```bash
open build/Skylight.app
```

`scripts/bundle.sh release` makes an optimized build, and `OPEN=1 scripts/bundle.sh` builds, then
launches. `swift build` alone compiles everything but doesn't make an app Chromium can run: the
framework and the five helper apps only come together in the bundle.

If you already run a copy of Skylight, `open` brings that one to the front instead, since both
have the same bundle id. Start the new build's executable directly instead (see the next section).

### Demo mode

For trying a change without touching your own tabs, cookies or passwords:

```bash
SKYLIGHT_DEV=1 SKYLIGHT_DATA_DIR="$(mktemp -d)" build/Skylight.app/Contents/MacOS/Skylight
```

- `SKYLIGHT_DATA_DIR` puts every file Skylight writes in that folder instead of
  `~/Library/Application Support/Skylight` (`state.json`, `preferences.json`, `Packages/`,
  `Engine/`, `mcp.json`, `engine.log`).
- `SKYLIGHT_DEV=1` keeps passwords in memory, with three made-up logins, instead of your login
  Keychain, and gives Chromium a mock keychain for its cookie key.
- `SKYLIGHT_DEBUG_PORT=9333` also exposes the Chrome DevTools Protocol on that port.

### Tests

```bash
swift test
```

116 tests in Swift Testing, over SkylightCore, SkylightKit and SkylightMCP. They use temporary
folders and in-memory stores only. `swift test -c release --filter Performance` prints the timings
quoted under Performance below.

`swift test` builds the whole package, CEFBridge included, so it needs CEF in `Vendor/cef` (run
`scripts/fetch-cef.sh` once). No test needs CEF, though, so without it you can build only the test
bundle and run that:

```bash
swift build --product SkylightPackageTests
swift test --skip-build
```

### Signing

By default `bundle.sh` signs ad hoc. That's enough to run on your own Mac. An ad hoc build is a
development build (`SkylightDevBuild` in its Info.plist): its signature changes on every build,
so it uses Chromium's mock keychain rather than asking for your login Keychain at every launch.

To sign with your own certificate, put it in `.signing` at the top of the repo. Git ignores the
file, so never commit it, and never put anything other than these variables in it:

```bash
SKYLIGHT_SIGN_IDENTITY="Apple Development: You (TEAMID)"
# Optional: a profile with Apple's web-browser.public-key-credential entitlement, for passkeys.
SKYLIGHT_PROVISIONING_PROFILE=path/to/Skylight.provisionprofile
```

`bundle.sh` reads it on every build (variables already set in your shell win). A signed build uses
the hardened runtime and your real Keychain. Keep to one identity: a build signed differently from
the last re-keys Chromium's cookies, and you are signed out of sites once.

The app icon is drawn in code: edit `scripts/make-icon.swift` and run it to regenerate
`Resources/AppIcon.icns`.

### Releases and updates

Signed builds update themselves with [Sparkle](https://sparkle-project.org). Every few hours they
read the feed on the repo's latest GitHub release and download a new version quietly. Then a card
at the bottom of the sidebar offers to restart; otherwise it installs when Skylight quits.
Skylight → Check for Updates… checks right away. Only builds signed with the project's update key
are installed. Development builds
(ad hoc, or `SKYLIGHT_DEV=1`) never update.

- `scripts/publish.sh 0.2.0` builds the app, signs the zip with the update key, writes
  `appcast.xml`, and puts both on a GitHub release. Installed copies pick it up from there. The
  top of the script lists what it needs. The repo has to be public for installed copies to
  download from it.
- `scripts/release.sh 0.2.0` builds `build/Skylight-0.2.0.dmg`: signed with a Developer ID,
  notarized and stapled, so a first install opens without warnings. It needs a Developer ID
  Application certificate and notary credentials saved with `xcrun notarytool
  store-credentials`. Until then, a first install from a published zip needs System Settings →
  Privacy & Security → Open Anyway.

## Modules

Skylight is one Swift package. Each module is a target in `Package.swift`, and depends only on
modules above it in this list:

| Module | What's in it |
|---|---|
| `SkylightCore` | State, actions, the reducer and store, persistence, themes, splits, omnibox parsing. No AppKit, no engine. |
| `SkylightEngine` | The `WebEngine`, `WebPage` and `ExtensionHost` protocols the rest of the app uses for web pages. |
| `SkylightKit` | Packages and boosts, Chrome extension manifests, native messaging hosts, passwords (Keychain, CSV, Chromium import). |
| `SkylightAgent` | The agent tool hub, built-in browser tools, page scripts and WebMCP. |
| `SkylightMCP` | The Model Context Protocol server on `127.0.0.1`. |
| `SkylightBrowser` | `Browser`, the object that owns every service and connects them: the store, pages, prompts, packages, agents, passwords, extensions, media. |
| `SkylightUI` | The SwiftUI window: sidebar, toolbar, address field, page area, Settings. |
| `SkylightCEF`, `CEFBridge` | The CEF engine: a Swift adapter over an Objective-C++ bridge. Only these two know about Chromium. |
| `Skylight`, `SkylightHelper` | The app executable, and Chromium's sub-process executable. |

[AGENTS.md](AGENTS.md) has the full map, where each kind of change goes, and the rules that keep it
working. [CONTRIBUTING.md](CONTRIBUTING.md) covers branches, commits and pull requests.
[docs/architecture.md](docs/architecture.md) lists known boundary problems and proposed fixes.

## Using it

| | |
|---|---|
| ⌘T | New tab: the address field opens for a search, a URL, any open tab or a command |
| ⌘L | Edit the current address |
| ⌘W / ⌘⇧T | Close tab / reopen it |
| ⌘D / ⌘⇧D | Pin the tab / add it to favorites |
| ⌘⇧K | Clear Today |
| ⌘S | Show or hide the sidebar |
| ⌘, | Settings |
| ⌃Tab | Next tab |
| ⌃1–9, ⌥⌘←/→ | Switch Space |
| ⌘⇧N | New Space |
| ⌃⌘N | Open a new tab beside this one, in a split |
| ⌃⌘[ / ⌃⌘] | Focus the previous / next pane of a split |
| ⌃⌘R | Rotate a split (side by side ↔ stacked) |
| ⌥⌘P | Picture in Picture |
| ⌘⇧B | Boost this site |
| ⌥⌘I | Developer tools |

The sidebar works like Arc's. **Favorites** at the top belong to every Space. Each Space has
**pinned** tabs, then **Today** (with **Clear**). Drag tabs between sections; the list shows an
insertion line where a tab will land, and holding a tab over a Space's button at the bottom
switches to that Space so you can drop it there. Links dragged in from a page or another app open
where you drop them. Closing a
pinned tab or favorite only unloads it; Delete in its menu removes it. Today tabs untouched for 12
hours are archived (⌘⇧T brings them back; the time is in Settings). Pages you haven't looked at in
20 minutes go to sleep and reload when you return.

Each Space has a color, an icon and a **profile**. A profile is a cookie jar: Spaces on different
profiles can be signed in to different accounts. Settings → Profiles names them and gives each an
icon and color; Settings → Spaces picks each Space's profile.

**Appearance.** Skylight follows the system's light or dark mode (Settings → Appearance can fix
it to one). The same page sets tab row size and which parts of the sidebar show. For something less
plain, **Sky behind the sidebar** puts a painted sky behind the source list: Sky, Pastel and Vivid
follow each Space's color; Paper, Graphite, Dusk, Forest, Ocean, Rosé and Aurora keep their own;
and you can make your own (sky, horizon and accent for light and dark, plus glow, sunlight, light
strength and glass under More colors). A Space can have its own sky in Settings → Spaces.

**Passwords** live in your login Keychain. After you sign in somewhere new, Skylight offers to save
the login; a key in the address field fills a saved one when you pick it. Filling only happens from
Skylight's own UI, and only into a page on the login's site. Settings → Passwords imports from
Aside, Arc, Chrome, Dia, Brave, Edge and other Chromium browsers on this Mac (macOS asks before
Skylight can read that browser's key), or from a CSV export (Chrome, Safari, 1Password, Bitwarden).
Copying and exporting ask for Touch ID or your password.

**Import** (File → Import From, or Settings → Import) brings over Arc's Spaces, pinned tabs and
favorites, or a Chromium browser's bookmarks: the bookmarks bar becomes favorites and each folder a
Space, which is how Aside's sidebar folders come across.

The sky is a small Metal shader: light falls through it, slowly, in the theme's colors. It runs at
30 fps only while it's showing and the window is in front, and stops with Reduce Motion or when
"Light through the sky" is off.

**Split view.** Drag a tab onto the page and drop it on a side (the drop zone shows where it will
go), or pick Open in Split View from a tab's menu, or press ⌃⌘N. Up to four panes go side by side or
stacked, with a hairline between them. Drag a divider to resize (double-click it to make the panes
equal), drag a pane's grip to move it or pull it out of the split, and click a pane to focus it. The
sidebar shows a split as one row; selecting any of its tabs shows them all. The outline on the
focused pane can be turned off in Settings → Appearance.

**Picture in Picture.** ⌥⌘P (or a tab's menu, or the address field) puts the page's main video in a
floating window. Leave a tab with a video playing and it follows you in Picture in Picture; come
back and it returns to the page (Settings → Appearance → Media turns this off). Tabs playing sound
show a speaker you can click to mute.

**Chrome extensions.** Settings → Extensions installs from a Chrome Web Store link (or the Web
Store button) or from an unpacked folder. Pinned extensions get a button in the toolbar; the rest
are in the Extensions menu (puzzle piece) next to them, where you pin and unpin. Settings can put
them all in the menu. Right-click a button to open its options or remove it. Popups open as bubbles sized to
their content. Extensions get Chrome's tabs and windows API (`tabs.query`, `tabs.update`,
`tabs.create`, `windows.getCurrent` and the rest), backed by Skylight's own tabs. They run in the
default profile only, and badges and tab events (`tabs.onActivated`) aren't supported yet.

## Packages

A package is a folder in `~/Library/Application Support/Skylight/Packages` with a `skylight.json`:

```json
{
  "id": "dev.you.reader",
  "name": "Reader tweaks",
  "matches": ["*://*.nytimes.com/*"],
  "styles": ["style.css"],
  "scripts": ["page.js"],
  "commands": [{ "id": "focus", "title": "Focus mode" }]
}
```

```js
// page.js runs at document start in matching pages. `skylight` is the package's API.
skylight.onReady(() => { /* the DOM is parsed */ });
skylight.addStyle('aside { display: none }');
skylight.command('focus', () => document.body.classList.toggle('focus'));
```

Saving a file reloads the package. CSS changes apply to open pages immediately; script changes
apply on the next load. Commands show up in the address field on matching sites. View → Boost This
Site (⌘⇧B) creates a package for the current site and opens its stylesheet.

## Agents (MCP and WebMCP)

Skylight runs a Model Context Protocol server on `127.0.0.1` (Streamable HTTP). Copy the connection
command from the Skylight menu (or the address field: "Copy Claude Code connection command"):

```bash
claude mcp add --transport http skylight http://127.0.0.1:47831/mcp --header "Authorization: Bearer <token>"
```

Tools: `list_tabs`, `open_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `select_tab`,
`close_tab`, `switch_space`, `read_page`, `click`, `type_text`, `scroll`, `call_site_tool`,
`run_package_command`, `list_packages`. Reading is free; anything that changes something shows an
approval alert first ("Allow for This Session" skips it for that agent until you quit).

Sites can offer their own tools through **WebMCP** (`navigator.modelContext`, the W3C community
group draft). Skylight provides the API in every page and forwards registered tools to agents: the
selected tab's tools appear as `site_<host>__<tool>`.

```js
navigator.modelContext.registerTool({
  name: 'search_flights',
  description: 'Searches flights between two airports.',
  inputSchema: { type: 'object', properties: { from: { type: 'string' }, to: { type: 'string' } } },
  execute: async ({ from, to }) => searchFlights(from, to),
});
```

The token in `mcp.json` (mode 600) is required on every request, and requests with a non-local
`Origin` are refused.

## Performance

Measured on an M5 Pro, release build, with `scripts/bench.py` (median of 3 launches, fresh data
folder each time) and `swift test -c release --filter Performance`.

| Bundle | |
|---|---|
| Skylight.app | 334 MB (Chromium is 326 MB of it; Skylight's own code is 4 MB) |
| Arc.app, for comparison | 870 MB |

| Runtime | window up | memory | idle CPU | processes |
|---|---|---|---|---|
| Empty tab | 0.45 s | 138 MB | 0.8% | 4 |
| One light page (example.com) | 0.45 s | 242 MB | 0.9% | 6 |
| One heavy page (swift.org, animated) | 0.44 s | 621 MB | 6.0% | 6 |
| Five tabs, one awake | 0.45 s | 286 MB | 0.7% | 6 |

Memory is physical footprint summed over Skylight and its helpers. Sleeping tabs cost almost
nothing: five tabs with one awake use about as much as one page.

| Hot paths | |
|---|---|
| The sky shader | 0.28 ms of GPU per frame at 1280×820, 30 fps: under 1% of the GPU, and zero while the window is in the background |
| A reducer action (open, select, close a tab) | 13–35 µs |
| Saving / loading 2,000 tabs | 12 ms / 18 ms (510 KB) |
| An MCP tools/list + tools/call round trip | 60 µs |
| Matching a package URL pattern | 0.7 µs |
| Importing 500 pinned tabs from Arc | 4 ms |

## Architecture

```
Skylight (app) ─┬─> SkylightUI ──> SkylightBrowser ─┬─> SkylightCore     state, reducer, store (pure)
                │                                   ├─> SkylightEngine   WebEngine protocols
                │                                   ├─> SkylightKit      packages, extensions, passwords
                │                                   ├─> SkylightAgent    tool hub, page scripts, WebMCP
                │                                   └─> SkylightMCP      MCP over local HTTP
                └─> SkylightCEF ──> CEFBridge (Objective-C++) ──> CEF
SkylightHelper: Chromium's sub-process executable.
```

- **One source of truth.** Every change, from a click, a shortcut, a package or an agent, is a
  `BrowserAction`. `BrowserReducer` applies it to `BrowserState` and returns `BrowserEffect`s; it
  never touches the engine. `PageCoordinator` turns effects into engine calls.
- **Tabs are not pages.** A tab is a saved place; a page is a live engine object that exists only
  while the tab is awake. Pages are created lazily and put to sleep by `HibernationPolicy`.
- **The engine is swappable.** Only `SkylightCEF` and `CEFBridge` know about Chromium.
- **System components first.** The window is a `NavigationSplitView` whose SwiftUI toolbar is
  bridged into the window's `NSToolbar`; the sidebar is a `List` with system drag and drop;
  Settings is an `NSTabViewController` of grouped `Form`s; prompts are alerts. Custom drawing is
  limited to what the system has no control for: split dividers, pane grips and the sky.

## Roadmap

1. **Now:** stock CEF 156 in Alloy style (embedded in our window).
2. **Self-built CEF** with ungoogled-chromium's privacy patches and proprietary codecs.
3. **Small patches toward full Chrome:** Chrome-style browsers inside a native parent view, so
   extensions get Chrome's own tab model (badges, tab events, per-profile extensions) instead of
   Skylight's shim. Today they're loaded over a private DevTools pipe (no port is opened) and a
   small shim maps Chrome's tabs and windows API onto Skylight's tabs. Passkeys.
4. Tab sync between machines, easels, notes and highlights as built-in packages, an in-app agent.

Profiles: Chromium only accepts profile folders directly inside its root, so the default profile
is now `Engine/Default` and others `Engine/Profile-<id>`. Earlier builds used `Engine/Profiles/<id>`,
which Chromium rejected ("Cannot create profile"), so pages there most likely never kept cookies;
you may need to sign in to sites again once.

Known limits: Google account sync is unavailable to third-party Chromium builds; Widevine (Netflix
and similar) needs Google's signing; iCloud passkeys need an Apple entitlement for browsers.

## License

MIT. CEF and Chromium are under their own BSD-style licenses (`Vendor/cef/LICENSE.txt`).
