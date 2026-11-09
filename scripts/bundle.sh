#!/usr/bin/env bash
# Builds Skylight.app.
#
#   scripts/bundle.sh            # debug build into build/Skylight.app
#   scripts/bundle.sh release    # optimized build
#   OPEN=1 scripts/bundle.sh     # build, then launch
#
# Signing is ad hoc unless you name a certificate:
#   SKYLIGHT_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" scripts/bundle.sh release
# signs with the hardened runtime and entitlements. Add
#   SKYLIGHT_PROVISIONING_PROFILE=path/to/Skylight.provisionprofile
# (one carrying Apple's web-browser.public-key-credential entitlement, which Apple grants to
# browsers on request) for iCloud Keychain passkeys and Touch ID. To sign every build the same
# way, put those lines in .signing at the top of the repo (it's ignored by git):
#   SKYLIGHT_SIGN_IDENTITY="Apple Development: You (TEAMID)"
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Skylight.app"
VERSION="${SKYLIGHT_VERSION:-0.1.0}"
# What updates compare: the commit count, so a build from a later commit is newer.
BUILD="${SKYLIGHT_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
# Where updates come from (scripts/publish.sh puts them there), and the key they're signed with.
FEED="https://potatoman03.github.io/skylight/appcast.xml"
UPDATE_KEY="MZEEASeQo9BloEsZVxVOKxWW+SxlzcsdyApewIsQz/k="
BUNDLE_ID="app.skylight.Skylight"
if [[ -z "${SKYLIGHT_SIGN_IDENTITY:-}" && -f "$ROOT/.signing" ]]; then source "$ROOT/.signing"; fi
IDENTITY="${SKYLIGHT_SIGN_IDENTITY:--}"
PROFILE="${SKYLIGHT_PROVISIONING_PROFILE:-}"
# An ad hoc signature changes every build, so the real Keychain would ask on every launch.
if [[ "$IDENTITY" == "-" ]]; then DEV_BUILD="<true/>"; else DEV_BUILD="<false/>"; fi
# release.sh sets this. A published build ignores the SKYLIGHT_ environment switches.
if [[ -n "${SKYLIGHT_PUBLISHED:-}" ]]; then PUBLISHED="<true/>"; else PUBLISHED="<false/>"; fi

cd "$ROOT"
swift build -c "$CONFIG" --product Skylight
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Skylight" "$APP/Contents/MacOS/Skylight"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN/Sparkle.framework" "$SPARKLE"
# The icon is drawn by scripts/make-icon.swift.
[[ -f "$ROOT/Resources/AppIcon.icns" ]] || swift "$ROOT/scripts/make-icon.swift"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Resources/Themes" "$APP/Contents/Resources/Themes"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Skylight</string>
  <key>CFBundleExecutable</key><string>Skylight</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Skylight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>SkylightDevBuild</key>$DEV_BUILD
  <key>SkylightPublished</key>$PUBLISHED
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$UPDATE_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>10800</integer>
  <key>NSCameraUsageDescription</key><string>Websites you allow can use your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use your microphone.</string>
  <key>NSLocationUsageDescription</key><string>Websites you allow can see your location.</string>
  <!-- http and https, and web pages, are what macOS looks for in a default browser. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.html</string>
        <string>public.xhtml</string>
        <string>public.svg-image</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Signed inside out. Distribution builds also need notarization.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$SPARKLE" >/dev/null
  codesign --force --sign - "$APP" >/dev/null
else
  ENT="$ROOT/build/entitlements"
  mkdir -p "$ENT"
  entitlements() { # file, then key=value pairs (true, or a string array as a,b)
    local file="$1"; shift
    { echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
      for pair in "$@"; do
        local key="${pair%%=*}" value="${pair#*=}"
        if [[ "$value" == "true" ]]; then echo "<key>$key</key><true/>"
        else echo "<key>$key</key><array>"; IFS=, read -ra items <<<"$value"; for i in "${items[@]}"; do echo "<string>$i</string>"; done; echo "</array>"; fi
      done
      echo '</dict></plist>'; } > "$file"
  }
  # Sites you allow can use the camera, microphone and USB security keys.
  app=(com.apple.security.device.camera=true com.apple.security.device.audio-input=true
       com.apple.security.device.usb=true)
  if [[ -n "$PROFILE" ]]; then
    TEAM="$(security cms -D -i "$PROFILE" | plutil -extract TeamIdentifier.0 raw -)"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    app+=(com.apple.developer.web-browser.public-key-credential=true
          "keychain-access-groups=$TEAM.$BUNDLE_ID.webauthn")
  fi
  entitlements "$ENT/app.plist" "${app[@]}"
  sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@" >/dev/null; }
  # Sparkle's helpers before Sparkle, as its documentation lays out.
  sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
  sign --entitlements "$ENT/app.plist" "$APP"
fi

echo "Built $APP"
if [[ "${OPEN:-0}" == "1" ]]; then open "$APP"; fi
