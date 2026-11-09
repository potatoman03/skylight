#!/usr/bin/env bash
# Builds a Skylight anyone can open: signed with your Developer ID, notarized by Apple, and
# packed in a disk image to drag into Applications.
#
#   scripts/release.sh 0.2.0     # writes build/Skylight-0.2.0.dmg
#
# Once per Mac:
# 1. A "Developer ID Application" certificate in your keychain (Xcode → Settings → Accounts →
#    Manage Certificates → + → Developer ID Application).
# 2. Notary credentials saved in your keychain, with an app-specific password from
#    account.apple.com:
#      xcrun notarytool store-credentials skylight-notary --apple-id you@example.com --team-id TEAMID
#
# The app is notarized and stapled before it goes in the disk image, so a copy dragged out of it
# opens offline too; then the disk image itself is.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${SKYLIGHT_NOTARY_PROFILE:-skylight-notary}"
APP="$ROOT/build/Skylight.app"
DMG="$ROOT/build/Skylight-$VERSION.dmg"

IDENTITY="${SKYLIGHT_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate in your keychain; see the top of $0." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notary credentials saved as \"$PROFILE\"; see the top of $0." >&2
  exit 1
fi

notarize() { # file: submit, wait, and stop with Apple's log if it's refused
  local out id
  out="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)"
  id="$(plutil -extract id raw - <<<"$out")"
  if [[ "$(plutil -extract status raw - <<<"$out")" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

SKYLIGHT_PUBLISHED=1 SKYLIGHT_SIGN_IDENTITY="$IDENTITY" SKYLIGHT_VERSION="$VERSION" SKYLIGHT_BUILD="$(git -C "$ROOT" rev-list --count HEAD)" \
  "$ROOT/scripts/bundle.sh" release

echo "Notarizing the app…"
ZIP="$(mktemp -d)/Skylight.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"

echo "Packing ${DMG}…"
# A dawn sky with the app, a line of light and Applications; Finder lays it out.
"$ROOT/scripts/dmg.sh" "$APP" "$DMG" "Skylight" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature "$DMG"
spctl --assess --type execute "$APP"
echo "Ready to send: $DMG"
