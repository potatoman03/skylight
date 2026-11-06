# Contributing to Skylight

Thanks for helping. This page covers how changes get in. [README.md](README.md) covers building,
and [AGENTS.md](AGENTS.md) covers the code: which module a change belongs in, and the rules that
keep it working. Read AGENTS.md before your first change. It's short, and it's written for people
as much as for coding agents.

## Branches and pull requests

- `main` is always buildable, and its tests pass. Nothing lands on it except through a pull
  request.
- Branch from the latest `main`, one branch per change: `fix/sidebar-drop-target`,
  `docs/contributing`, `feature/tab-sync`. Experiments that may never merge go on `spike/…`
  branches, with a write-up in `docs/` saying what was learned.
- Keep a pull request to one idea. A refactor and the feature that needed it are easier to review
  as two pull requests.
- Rebase on `main` before asking for review, and again if `main` moves under you. Fix conflicts on
  your branch, not in the merge.
- CI (`.github/workflows/ci.yml`) has to pass. It runs the tests, then builds an ad hoc signed
  app bundle.

## Commit messages

Match the history (`git log`). The subject line says what changed for someone using Skylight, in
plain words and the imperative, with no prefix like `feat:` and no full stop:

```
Rename tabs; hang suggestions under the address field
Fix crash when a typed query matches a tab's title but not its address
```

Put two related changes in one subject with a semicolon. Leave the body out of a change the subject
fully describes. Otherwise, after a blank line, say what someone will notice and why it works that
way, wrapped at about 72 columns:

```
Fix sidebar rows ignoring clicks; plainer toolbar

A tab row's drag handler kept its clicks from the list, so rows rarely
selected. Rows now select themselves on tap, as favorites and split
panes already did.
```

A larger change can use a short bulleted list in the body instead. If a coding agent helped write
the change, end the message with its trailer, for example
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

Stage files by name (`git add Sources/SkylightCore/Tidy.swift`), not `git add -A`. Never commit
`.signing`, `Vendor/`, `build/` or `.build/`. Git ignores them, so don't force them in.

## Running the tests

```bash
swift test
```

`swift test --filter ReducerTests` runs one suite. Tests use Swift Testing (`@Suite`, `@Test`,
`#expect`). Each new test goes in the suite for its module: `Tests/SkylightCoreTests`,
`Tests/SkylightKitTests` or `Tests/SkylightMCPTests`.

Tests never touch your real data: they use `FileManager.default.temporaryDirectory`,
`InMemoryStateStore` and `MemoryCredentialStore`, never `AppPaths.standard()`, the login
Keychain, another browser's real profile, or the Chrome Web Store. Keep it that way. A test that
needs any of those is a test of the wrong layer.

For anything you can see, also run the app in demo mode (README, "Demo mode") and try the change by
hand, with Reduce Motion both on and off if it moves.

## What a good pull request has

- **What and why** in the description: the problem, what you changed, and anything you chose not
  to do. Link the issue if there is one.
- **Tests** for logic. Reducer actions, parsing, matching, importers and MCP handling are all
  testable without a window. If you couldn't test something, say why.
- **Screenshots or a short recording** for UI changes, in light and dark mode.
- **How you checked it:** the commands you ran and what you tried in the app.
- **Docs** updated with the change: README for anything a user sees, AGENTS.md if you move a
  boundary or add a rule, `docs/architecture.md` for a design change.
- **No unrelated changes:** no drive-by reformatting, no renamed files you didn't otherwise touch.

## Code style

There's no formatter. Match the code around you.

- **Doc comments say why, briefly, in plain words.** The name and signature already say what.
  The comment says what isn't obvious: the reason, the constraint, what goes wrong otherwise.
  From the codebase:

  ```swift
  /// Hosts the coordinator's page container. SwiftUI never re-creates it, so pages keep running.

  // A new set of scripts reaches each page at its next load.
  ```

  Write for a user or a new contributor, not in jargon. One or two lines is usual. No comment is
  better than one that repeats the code.
- **Swift 6 strict concurrency.** UI, the store and services are `@MainActor`. Mark values that
  cross actors `Sendable` rather than silencing the checker.
- **State changes are actions.** Add a case to `BrowserAction` and handle it in `BrowserReducer`.
  Don't mutate `BrowserState` from a view or a service (see AGENTS.md).
- **System components first.** Use what macOS already has (List, Form, toolbars, alerts, menus)
  before drawing your own.
- **Four-space indents.** Code and comments wrap at about 100 columns, longer only when breaking
  would hurt.
- **No new package dependencies** without asking in an issue first. Skylight has none today
  besides Sparkle.
- **User-facing text** is sentence case, short and friendly ("Couldn't install the extension"),
  in American spelling.

## Reporting bugs and asking for features

Use the issue templates. For a bug, include the macOS version, the Skylight commit
(`git rev-parse --short HEAD`), the steps, and `engine.log` from the data folder if pages
misbehave. Remove anything private from it first. Report security problems privately to the
maintainer, not in a public issue.
