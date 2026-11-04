# Skylight

![Skylight](docs/screenshot.png)

An open-source browser for macOS in the spirit of Arc: a native SwiftUI shell with Liquid Glass,
Spaces and a vertical sidebar, around Chromium (via CEF). Built to be light, easy to extend, and
usable by AI agents as a first-class citizen.

## Build and run

Requirements: macOS 26, Xcode 26 (Swift 6.2+), `cmake` and `ninja` (`brew install cmake ninja`).

```bash
scripts/bundle.sh
```

The first run downloads CEF (~300 MB) into `Vendor/cef` and builds its C++ wrapper. Then:

```bash
open build/Skylight.app
```

`scripts/bundle.sh release` makes an optimized build. Tests: `swift test`.

Data lives in `~/Library/Application Support/Skylight` (`state.json`, `preferences.json`, `Packages/`,
`Engine/`, `mcp.json`). Set `SKYLIGHT_DATA_DIR` to run against another folder, and
`SKYLIGHT_DEBUG_PORT=9333` to expose Chrome DevTools Protocol for debugging.

## Using it

| | |
|---|---|
| ⌘T | Command bar: search, open a URL, switch to any tab, run commands |
| ⌘L | Edit the current address |
| ⌘W / ⌘⇧T | Close tab / reopen it |
| ⌘D / ⌘⇧D | Pin the tab / add it to favorites |
| ⌘⇧K | Clear Today |
| ⌘S | Hide the sidebar (it slides back when the pointer touches the left edge) |
| ⌘, | Settings (a page in the browser, `skylight://settings`) |
| ⌃Tab | Next tab |
| ⌃1–9, ⌥⌘←/→ | Switch Space |
| ⌘⇧N | New Space |
| ⌘⇧B | Boost this site |
| ⌥⌘I | Developer tools |

The sidebar works like Arc's. **Favorites** at the top belong to every Space. Each Space has
**pinned** tabs, then a line with **Clear**, then **Today**. Drag tabs between them. Closing a
pinned tab or favorite only unloads it; Delete in its menu removes it. Today tabs untouched for 12
hours are archived (⌘⇧T brings them back; the time is in Settings). Pages you haven't looked at in
20 minutes go to sleep and reload when you return.

Each Space has a color, an icon and a **profile**. A profile is a cookie jar: Spaces on different
profiles can be signed in to different accounts. Manage them in Settings → Profiles, or from a
Space's ⋯ menu.

**Import** (File menu or Settings → Import) brings over Arc's Spaces, pinned tabs and favorites, or
Chrome's bookmarks.

The sky behind everything is a small Metal shader: light falls through it, slowly, in the active
Space's color. It runs at 30 fps only while the window is in front, and stops with Reduce Motion or
when "Light through the sky" is off.

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
apply on the next load. Commands show up in the command bar on matching sites. View → Boost This
Site (⌘⇧B) creates a package for the current site and opens its stylesheet.

## Agents (MCP and WebMCP)

Skylight runs a Model Context Protocol server on `127.0.0.1` (Streamable HTTP). Copy the connection
command from the Skylight menu (or the command bar: "Copy Claude Code connection command"):

```bash
claude mcp add --transport http skylight http://127.0.0.1:47831/mcp --header "Authorization: Bearer <token>"
```

Tools: `list_tabs`, `open_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `select_tab`,
`close_tab`, `switch_space`, `read_page`, `click`, `type_text`, `scroll`, `call_site_tool`,
`run_package_command`, `list_packages`. Reading is free; anything that changes something shows an
approval card first ("Allow for This Session" skips the card for that agent until you quit).

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
                │                                   ├─> SkylightKit      packages
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
- **Motion follows a few rules** (`SkylightUI/Motion.swift`): nothing pops, one object makes one
  trip (the command bar is the URL pill, grown), neighbors make room, feedback is fast, and Reduce
  Motion turns movement into fades.

## Roadmap

1. **Now:** stock CEF 156 in Alloy style (embedded in our window).
2. **Self-built CEF** with ungoogled-chromium's privacy patches and proprietary codecs.
3. **Small patches toward full Chrome:** Chrome-style browsers inside a native parent view (for the
   Chrome extension system), the password manager and autofill, passkeys.
4. Tab sync between machines, easels, notes and highlights as built-in packages, an in-app agent.

Known limits: Google account sync is unavailable to third-party Chromium builds; Widevine (Netflix
and similar) needs Google's signing; iCloud passkeys need an Apple entitlement for browsers.

## License

MIT. CEF and Chromium are under their own BSD-style licenses (`Vendor/cef/LICENSE.txt`).
