## What and why

<!-- The problem, what you changed, and anything you chose not to do. Link the issue: "Fixes #…". -->

## How I checked it

- [ ] `swift build`
- [ ] `swift test` (or `swift build --product SkylightPackageTests && swift test --skip-build` without CEF)
- [ ] Tried it in the app: `scripts/bundle.sh`, then `SKYLIGHT_DEV=1 SKYLIGHT_DATA_DIR="$(mktemp -d)" build/Skylight.app/Contents/MacOS/Skylight`
- [ ] Light and dark mode, and Reduce Motion if it animates

<!-- What you tried by hand, and anything you couldn't check. -->

## Screenshots

<!-- For UI changes: before and after, light and dark. Delete this section otherwise. -->

## Checklist

- [ ] Tests for new logic (reducer actions, parsing, matching, MCP)
- [ ] Docs updated: README for what users see, AGENTS.md for a new boundary or rule
- [ ] No WebKit types outside `SkylightWebKit`
- [ ] Tests don't touch real profiles, the login Keychain or the Chrome Web Store
- [ ] Commit messages follow CONTRIBUTING.md, and `.signing` isn't committed
