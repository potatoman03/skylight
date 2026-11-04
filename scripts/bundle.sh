#!/usr/bin/env bash
# Builds Skylight.app: the app executable, the Chromium framework, and the five helper apps
# Chromium launches for its sub-processes.
#
#   scripts/bundle.sh            # debug build into build/Skylight.app
#   scripts/bundle.sh release    # optimized build
#   OPEN=1 scripts/bundle.sh     # build, then launch
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF="$ROOT/Vendor/cef"
APP="$ROOT/build/Skylight.app"
VERSION="0.1.0"
BUNDLE_ID="app.skylight.Skylight"

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
  <key>SkylightDevBuild</key><true/>
  <key>NSCameraUsageDescription</key><string>Websites you allow can use your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use your microphone.</string>
  <key>NSLocationUsageDescription</key><string>Websites you allow can see your location.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Websites you allow can connect to Bluetooth devices.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
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

# Ad-hoc signature, inside out. Distribution builds need a Developer ID and notarization.
codesign --force --sign - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null
for helper in "$APP/Contents/Frameworks/"*Helper*.app; do codesign --force --sign - "$helper" >/dev/null; done
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
if [[ "${OPEN:-0}" == "1" ]]; then open "$APP"; fi
