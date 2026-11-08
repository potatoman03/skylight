#!/usr/bin/env bash
# Packs Skylight in a disk image whose window is a dawn sky, with the app on the left, a line of
# light, and Applications on the right. `release.sh` uses it; on its own it makes an unsigned one
# to look at:
#
#   scripts/dmg.sh build/Skylight.app build/Skylight-test.dmg "Skylight"
#
# Finder lays the window out, so this needs a logged-in Mac, and macOS asks once to let the
# terminal control Finder.
set -euo pipefail

APP="${1:?usage: scripts/dmg.sh APP OUT.dmg VOLUME_NAME}"
OUT="${2:?usage: scripts/dmg.sh APP OUT.dmg VOLUME_NAME}"
VOLUME="${3:?usage: scripts/dmg.sh APP OUT.dmg VOLUME_NAME}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mount" -quiet -force 2>/dev/null || true; rm -rf "$WORK"' EXIT

# The window's picture, at 1x and 2x in one file, so it's sharp on any screen.
swift "$ROOT/scripts/dmg-background.swift" "$ROOT/Resources/Themes/skylight-default-light.jpg" "$WORK/art"
tiffutil -cathidpicheck "$WORK/art/background.png" "$WORK/art/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/Skylight.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$WORK/background.tiff" "$WORK/stage/.background/background.tiff"

# Writable first, so Finder can save the layout into it.
hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov -quiet "$WORK/rw.dmg"
mkdir -p "$WORK/mount"
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$WORK/mount" -quiet

# 660 by 420 inside, the icons where the picture expects them (see dmg-background.swift).
osascript <<EOF
tell application "Finder"
    set theDisk to (POSIX file "$WORK/mount" as alias)
    open theDisk
    set theWindow to container window of theDisk
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set bounds of theWindow to {200, 120, 860, 568}
    set options to icon view options of theWindow
    set arrangement of options to not arranged
    set icon size of options to 112
    set text size of options to 13
    set shows item info of options to false
    set background picture of options to file ".background:background.tiff" of theDisk
    set position of item "Skylight.app" of theDisk to {170, 228}
    set position of item "Applications" of theDisk to {490, 228}
    update theDisk without registering applications
    delay 1
    close theWindow
end tell
EOF

chflags hidden "$WORK/mount/.background"
sync
hdiutil detach "$WORK/mount" -quiet
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format ULMO -o "$OUT" -quiet
echo "$OUT"
