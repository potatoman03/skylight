#!/usr/bin/env bash
# Publishes a release: signs it with your Developer ID and has Apple notarize it (scripts/release.sh),
# zips it, signs the zip with the update key, writes the update feed, and puts them on a GitHub
# release. Skylight reads the feed from the latest release (SUFeedURL in bundle.sh), so the newest
# release wins. The release also gets Skylight.dmg for new people: its name never changes, so the
# website's link to releases/latest/download/Skylight.dmg is always the newest.
#
#   scripts/publish.sh 0.2.0
#
# Needs:
# - What scripts/release.sh needs: a Developer ID Application certificate and notary credentials.
# - The update key in your keychain. `generate_keys --account skylight` (in
#   .build/artifacts/sparkle/Sparkle/bin) made it. Back it up with
#   `generate_keys --account skylight -x skylight-update-key.txt` and keep that file somewhere
#   safe and private: installed copies take updates signed with this key only.
# - gh signed in to an account that can make releases on the repo, and the commit pushed.
# - The repo public, for installed copies to download from it.
set -euo pipefail

VERSION="${1:?usage: scripts/publish.sh VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SKYLIGHT_REPO:-potatoman03/skylight}"
APP="$ROOT/build/Skylight.app"
OUT="$ROOT/build/releases/$VERSION"
ZIP="$OUT/Skylight-$VERSION.zip"
DMG="$OUT/Skylight.dmg"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

cd "$ROOT"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Commit your changes first: a release is built from a commit." >&2; exit 1
fi
if [[ -z "$(git branch -r --contains HEAD)" ]]; then
  echo "Push $(git rev-parse --short HEAD) first: the release points at it." >&2; exit 1
fi

BUILD="$(git rev-list --count HEAD)"
swift package resolve
scripts/release.sh "$VERSION"

mkdir -p "$OUT"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
cp "$ROOT/build/Skylight-$VERSION.dmg" "$DMG"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account skylight "$ZIP")"

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Skylight</title>
    <item>
      <title>Skylight $VERSION</title>
      <pubDate>$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Skylight-$VERSION.zip" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

gh release create "v$VERSION" "$ZIP" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Skylight $VERSION" --generate-notes
echo "Published Skylight $VERSION (build $BUILD). New people get it from the website; everyone else gets it as an update."
