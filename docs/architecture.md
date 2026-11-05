# Architecture notes

What the module boundaries are meant to be is in [AGENTS.md](../AGENTS.md). This page records
where the code doesn't match them yet, and what to do about it. Small, clear fixes were made
directly. The rest are proposals, roughly in order of value. Each is a change of its own, not
something to fold into a feature.

## Fixed

- **Command bar actions lived in SkylightUI.** `Browser.presentCommandBar(_:)` and
  `dismissCommandBar()` were an `extension Browser` in `AddressBar.swift`, and the app target
  called them from there. They use only the store, the command bar model and the page
  coordinator, so they now live in `Browser.swift`, with the same names and signatures.
- **Undeclared dependencies.** The `Skylight` app imported SkylightBrowser, SkylightCore and
  SkylightKit, and SkylightCEF imported SkylightCore, without declaring them. They built only
  because the modules came in transitively. `Package.swift` now lists them.
- **SkylightKit's description.** `Package.swift` and the README called it "packages", but it also
  holds extension manifests, native messaging hosts and passwords. The descriptions now say so.
  (Splitting it is proposal 4.)
- **A flaky test.** `storeSavesAfterChanges` waited a fixed 100 ms for a save that runs on the main
  actor, which the benchmarks can hold for seconds when suites run in parallel. It failed about 1
  run in 10. It now waits for the save, with a deadline.
- **`.gitignore`** ignores `/Vendor` (file or folder), so a git worktree with `Vendor` symlinked
  to the main checkout's CEF stays clean.

## Proposals

### 1. Tab drops as one reducer action

`Browser.drop(_:on:)` in `SkylightUI/TabDrag.swift` decides what a drop means: it leaves a split,
moves the tab to the active Space, takes it out of its folder, works out the index with the
sidebar's row model, then moves it. That's several `store.send` calls, so the state passes
through in-between states, each schedules a save, and none of it is tested.

Proposal: add `BrowserAction.dropTab(TabID, DropTarget)` to SkylightCore, with `DropTarget`
(section and row, favorites index, folder and index, Space, split pane and edge) as a Core type.
The reducer does the whole move in one step. The row counting in `SidebarRows` moves to Core
with it, since it's pure. `TabDragSession` (pasteboard encoding) stays in UI. Add reducer tests
for each target, including the off-by-one cases the current code comments on.

### 2. Tests for SkylightBrowser, with a fake engine

SkylightBrowser has no test target, though it holds most of the behavior that isn't the reducer:
hibernation, which pages are visible, prompts, agent tools, package reloads, the password flows.
`WebEngine` was designed to be swappable, so a `FakeEngine`/`FakePage` (recording calls,
returning canned `evaluate` results) would make it testable without CEF.

Proposal: add `Tests/SkylightBrowserTests` with a fake engine, starting with `PageCoordinator`
(wake, sleep, the visible set, `discardPage`) and `AgentService` tool calls end to end against
`ToolHub`. AppKit in the services (proposal 3) is the main obstacle. Start with the parts that
don't touch it.

### 3. AppKit calls in services, behind one seam

SkylightBrowser is meant to be orchestration, but some services drive AppKit directly:

- `ExtensionService.askToAdd` builds and runs an `NSAlert` (install and update consent),
  bypassing `PromptCenter`. Every other prompt goes through `PromptCenter`.
- `PasswordService` opens `NSOpenPanel`/`NSSavePanel` and writes to `NSPasteboard`.
- `Browser` and `PackageService` use `NSPasteboard` and `NSWorkspace`.

Proposal: make extension consent a `Prompt` case (`.extensionConsent(manifest, warnings, respond)`)
answered by the alert host, like permissions and agent approvals. Then put the rest (pasteboard,
open and save panels, reveal in Finder) behind a small `SystemServices` protocol that `Browser`
takes in its initializer, with the AppKit version made in `AppDelegate`. Services become
testable, and the UI owns every window that appears. (The alert host is in `ContentArea.swift`;
see "Changes to files under edit" below.)

### 4. Split SkylightKit

SkylightKit holds four unrelated things: packages, Chrome extension manifests, native messaging
hosts, and passwords (Keychain, CSV, Chromium's encrypted `Login Data`, with Security, SQLite3
and CommonCrypto). They share nothing except SkylightCore.

Proposal: `SkylightPackages` (manifest, loader, match patterns, scripts, directory watcher),
`SkylightExtensions` (manifest, native messaging hosts), `SkylightPasswords`. Each gets its own
test target from the current `SkylightKitTests` files. It's mechanical but touches every
`import SkylightKit`, so it's worth doing while few branches are open.

### 5. Parse launch options once

`main.swift` works out `devBuild` (`SKYLIGHT_DEV` or `SkylightDevBuild` in Info.plist) and passes
it to CEF as the mock keychain. `AppDelegate.engineDidStart` checks `SKYLIGHT_DEV` again on its own
to pick `MemoryCredentialStore.demo()`. So an ad hoc build without `SKYLIGHT_DEV` uses Chromium's
mock keychain, but the real login Keychain for passwords. That may be intended, so passwords
saved in a development build persist, but nothing says so.

Proposal: a `LaunchOptions` struct (data folder, dev build, demo passwords, debug port) parsed
once in `main.swift` and passed to `AppDelegate`, with the ad hoc-build password behavior decided
and written down there. Behavior doesn't change until someone decides it should.

### 6. Default browser handling out of Settings

`DefaultBrowser` (asks `NSWorkspace` which app opens `https`, and asks macOS to make it Skylight)
is in `SettingsView.swift`. It's system integration, not a view. A menu item, a first-run prompt or
an agent tool can't reach it from there. Proposal: move it to SkylightBrowser, behind proposal
3's `SystemServices`.

## Changes to files under edit

`Sidebar.swift`, `ContentArea.swift`, `Motion.swift` and `CEFBridge/SKBrowser.mm` were being
changed on another branch while this was written, so nothing here touched them. Once that work
lands:

- **`ContentArea.swift`**: the prompt alert host renders the new extension-consent prompt from
  proposal 3, and its `PaneLayout` math stays in step with `PageHostView.arrange` (see
  proposal 1 for the drop side).
- **`Sidebar.swift`**: context-menu actions that send several actions in a row should use
  proposal 1's single action once it exists. It imports SkylightAgent only for `AgentActivity`,
  which is fine.
- **`Motion.swift`**: no boundary issues. Its rule (only SwiftUI views animate, pages resize at
  once) is now in AGENTS.md, so keep the two in step.
- **`SKBrowser.mm`**: no boundary issues found.

## Future work: releases

Not built yet. The plan:

1. Sign with a **Developer ID Application** certificate through `bundle.sh`'s existing signed
   path (hardened runtime and nested CEF libraries are already handled).
2. **Notarize** with `xcrun notarytool submit --wait`, then `xcrun stapler staple`.
3. Package a **DMG** (signed, notarized and stapled too).
4. **Sparkle** for updates: an EdDSA-signed appcast, `SUFeedURL` and `SUPublicEDKey` in
   Info.plist, and Sparkle's framework signed inside out like CEF's.
5. A tag-triggered CI job holding the certificate and notary credentials as secrets, and
   `VERSION` in `bundle.sh` read from the tag instead of the hard-coded `0.1.0`.
