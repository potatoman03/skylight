#!/usr/bin/env bash
# Builds Skylight.app: the app executable, the Chromium framework, and the five helper apps
# Chromium launches for its sub-processes.
#
#   scripts/bundle.sh            # debug build into build/Skylight.app
#   scripts/bundle.sh release    # optimized build
#   OPEN=1 scripts/bundle.sh     # build, then launch
#
# Signing is ad hoc unless you name a certificate:
#   SKYLIGHT_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" scripts/bundle.sh release
# signs with the hardened runtime and entitlements, and uses your real Keychain for Chromium's
# cookie encryption. Switching an existing profile over logs you out of sites once. Add
#   SKYLIGHT_PROVISIONING_PROFILE=path/to/Skylight.provisionprofile
# (one carrying Apple's web-browser.public-key-credential entitlement, which Apple grants to
# browsers on request) for iCloud Keychain passkeys and Touch ID. To sign every build the same
# way, put those lines in .signing at the top of the repo (it's ignored by git):
#   SKYLIGHT_SIGN_IDENTITY="Apple Development: You (TEAMID)"
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF="$ROOT/Vendor/cef"
APP="$ROOT/build/Skylight.app"
VERSION="0.1.0"
BUNDLE_ID="app.skylight.Skylight"
# A build signed differently from the last re-keys Chromium's cookies, so keep to one identity.
if [[ -z "${SKYLIGHT_SIGN_IDENTITY:-}" && -f "$ROOT/.signing" ]]; then source "$ROOT/.signing"; fi
IDENTITY="${SKYLIGHT_SIGN_IDENTITY:--}"
PROFILE="${SKYLIGHT_PROVISIONING_PROFILE:-}"
# An ad hoc signature changes every build, so the real Keychain would ask on every launch.
if [[ "$IDENTITY" == "-" ]]; then DEV_BUILD="<true/>"; else DEV_BUILD="<false/>"; fi

[[ -d "$CEF/Release" ]] || "$ROOT/scripts/fetch-cef.sh"
[[ -f "$CEF/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]] || "$ROOT/scripts/build-cef-wrapper.sh"

cd "$ROOT"
swift build -c "$CONFIG" --product Skylight
swift build -c "$CONFIG" --product SkylightHelper
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Skylight" "$APP/Contents/MacOS/Skylight"
ditto "$CEF/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
# The icon is drawn by scripts/make-icon.swift.
[[ -f "$ROOT/Resources/AppIcon.icns" ]] || swift "$ROOT/scripts/make-icon.swift"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>SKApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>SkylightDevBuild</key>$DEV_BUILD
  <key>NSCameraUsageDescription</key><string>Websites you allow can use your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use your microphone.</string>
  <key>NSLocationUsageDescription</key><string>Websites you allow can see your location.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Websites you allow can connect to Bluetooth devices.</string>
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

# Chromium looks for "<App> Helper (<Kind>).app" next to the framework.
for kind in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
  name="Skylight Helper$kind"
  suffix="$(echo "$kind" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
  id="$BUNDLE_ID.helper${suffix:+.$suffix}"
  contents="$APP/Contents/Frameworks/$name.app/Contents"
  mkdir -p "$contents/MacOS"
  cp "$BIN/SkylightHelper" "$contents/MacOS/$name"
  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><string>1</string>
  <key>LSFileQuarantineEnabled</key><true/>
  <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
done

# Signed inside out. Distribution builds also need notarization.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null
  for helper in "$APP/Contents/Frameworks/"*Helper*.app; do codesign --force --sign - "$helper" >/dev/null; done
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
  # The renderer and GPU processes compile JavaScript and shaders; the rest need nothing extra.
  entitlements "$ENT/jit.plist" com.apple.security.cs.allow-jit=true
  entitlements "$ENT/plain.plist"
  # Sites you allow can use the camera, microphone, Bluetooth and USB security keys.
  app=(com.apple.security.device.camera=true com.apple.security.device.audio-input=true
       com.apple.security.device.bluetooth=true com.apple.security.device.usb=true)
  if [[ -n "$PROFILE" ]]; then
    TEAM="$(security cms -D -i "$PROFILE" | plutil -extract TeamIdentifier.0 raw -)"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    app+=(com.apple.developer.web-browser.public-key-credential=true
          "keychain-access-groups=$TEAM.$BUNDLE_ID.webauthn")
  fi
  entitlements "$ENT/app.plist" "${app[@]}"
  sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@" >/dev/null; }
  # Its libraries first: signing the framework doesn't re-sign them, and the hardened runtime
  # won't load code signed by another team.
  for lib in "$APP/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/"*.dylib; do sign "$lib"; done
  sign "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  for helper in "$APP/Contents/Frameworks/"*Helper*.app; do
    case "$helper" in *"(Renderer)"*|*"(GPU)"*) sign --entitlements "$ENT/jit.plist" "$helper" ;; *) sign --entitlements "$ENT/plain.plist" "$helper" ;; esac
  done
  sign --entitlements "$ENT/app.plist" "$APP"
fi

echo "Built $APP"
if [[ "${OPEN:-0}" == "1" ]]; then open "$APP"; fi
