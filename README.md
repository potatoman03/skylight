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
| ⌃⌘N | Open a new tab beside this one, in a split |
| ⌃⌘[ / ⌃⌘] | Focus the previous / next pane of a split |
| ⌃⌘R | Rotate a split (side by side ↔ stacked) |
| ⌥⌘P | Picture in Picture |
| ⌘⇧B | Boost this site |
| ⌥⌘I | Developer tools |

The sidebar works like Arc's. **Favorites** at the top belong to every Space. Each Space has
**pinned** tabs, then a line with **Clear**, then **Today**. Drag tabs between them: the rows part
to show where a tab will land, favorites make room in their grid, holding a tab over a Space's
button at the bottom switches to that Space so you can drop it there, and Escape cancels. Closing a
pinned tab or favorite only unloads it; Delete in its menu removes it. Today tabs untouched for 12
hours are archived (⌘⇧T brings them back; the time is in Settings). Pages you haven't looked at in
20 minutes go to sleep and reload when you return.

Each Space has a color, an icon and a **profile**. A profile is a cookie jar: Spaces on different
profiles can be signed in to different accounts. In Settings → Profiles each profile is a card with
its own icon and color; click a Space's chip to move it onto that profile.

**Themes.** The paintbrush at the bottom of the sidebar switches theme and light/dark in one click,
for every Space or just the one you're in. Settings → Appearance has the gallery (Sky, Pastel and
Vivid follow each Space's color; Paper, Graphite, Dusk, Forest, Ocean, Rosé and Aurora keep their
own) and an editor for your own themes: sky, horizon and accent for light and dark, plus glow,
sunlight, light strength and glass under More Colors. Edits apply live. The same page sets tab row
density, page corner radius, and which parts of the sidebar show. `Theme: …` in the command bar
switches too.

**Passwords** live in your login Keychain. After you sign in somewhere new, Skylight offers to save
the login; a key in the address bar fills a saved one when you pick it. Filling only happens from
Skylight's own UI, and only into a page on the login's site. Settings → Passwords imports from
Aside, Arc, Chrome, Dia, Brave, Edge and other Chromium browsers on this Mac (macOS asks before
Skylight can read that browser's key), or from a CSV export (Chrome, Safari, 1Password, Bitwarden).
Copying and exporting ask for Touch ID or your password.

**Import** (File → Import From, or Settings → Import) brings over Arc's Spaces, pinned tabs and
favorites, or a Chromium browser's bookmarks: the bookmarks bar becomes favorites and each folder a
Space, which is how Aside's sidebar folders come across.

The sky behind everything is a small Metal shader: light falls through it, slowly, in the theme's
colors. It runs at 30 fps only while the window is in front, and stops with Reduce Motion or when
"Light through the sky" is off.

**Split view.** Drag a tab onto the page and drop it on a side (the drop zone shows where it will
go), or pick Open in Split View from a tab's menu, or press ⌃⌘N. Up to four panes go side by side or
stacked; each is its own card on the sky. Drag a divider to resize (double-click it to make the panes
equal), drag a pane's grip to move it or pull it out of the split, and click a pane to focus it. The
sidebar shows a split as one row; selecting any of its tabs shows them all. The gap between panes
and the outline on the focused pane are in Settings → Appearance.

**Picture in Picture.** ⌥⌘P (or a tab's menu, or the command bar) puts the page's main video in a
floating window. Leave a tab with a video playing and it follows you in Picture in Picture; come
back and it returns to the page (Settings → Appearance → Media turns this off). Tabs playing sound
show a speaker you can click to mute.

**Chrome extensions.** Settings → Extensions installs from a Chrome Web Store link (or the Web
Store button) or from an unpacked folder. Toolbar buttons sit in the address bar, in their own row
under it, or behind the puzzle-piece menu (your choice in the same settings); right-click one to
pin, unpin, open its options or remove it, and drag to reorder. Popups open as bubbles sized to
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
