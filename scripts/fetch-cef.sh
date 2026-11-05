#!/usr/bin/env bash
# Downloads the CEF binary distribution into Vendor/cef and builds libcef_dll_wrapper.
# Needs cmake and ninja (brew install cmake ninja).
set -euo pipefail

CEF_VERSION="${CEF_VERSION:-156.0.15+gcf671c0+chromium-156.0.8078.80}"
PLATFORM="macosarm64"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/cef"

if [[ -f "$DEST/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" ]]; then
  echo "CEF is already in Vendor/cef."
else
  name="cef_binary_${CEF_VERSION}_${PLATFORM}"
  url="https://cef-builds.spotifycdn.com/$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name").tar.bz2"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  # Braces: in a UTF-8 locale, macOS's bash 3.2 reads the "…" as part of the variable's name,
  # stops with "unbound variable", and still exits 0.
  echo "Downloading ${name}…"
  curl --fail --location --progress-bar "$url" -o "$work/cef.tar.bz2"
  mkdir -p "$work/x"
  tar -xjf "$work/cef.tar.bz2" -C "$work/x"
  rm -rf "$DEST"
  mkdir -p "$ROOT/Vendor"
  mv "$work/x/$name" "$DEST"
fi

"$ROOT/scripts/build-cef-wrapper.sh"
