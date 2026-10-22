#!/bin/bash
# Builds build/muxFinder.app (PLAN.md D7, D22): a release arm64 build of the menu bar app and
# its launch helper, assembled into a bundle and signed.
#
#   scripts/build-app.sh
#
# - Bundle: Contents/MacOS/muxFinder (the app) and Contents/MacOS/muxfinder-launch (the
#   helper iTerm2 runs; LaunchHelperPath.locate() looks for it next to the app's executable),
#   Contents/Info.plist (bundle id cc.carpio.muxfinder, LSUIElement, LSMinimumSystemVersion
#   14.0, NSAppleEventsUsageDescription) and Contents/PkgInfo.
# - Signing: the first "Apple Development" identity in the keychain, or the identity named by
#   MUXFINDER_SIGN_IDENTITY; hardened runtime; the app gets the
#   com.apple.security.automation.apple-events entitlement and no sandbox. Without an
#   identity it signs ad hoc and warns that macOS permission grants (Automation) reset on
#   every build. The bundle is never notarized.
# - Every value written into the bundle is a constant of this script; nothing is built from
#   the environment except the signing identity, which is passed to codesign as one argument.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/muxFinder.app"
ENTITLEMENTS="$ROOT/build/muxFinder.entitlements"
TRIPLE="arm64-apple-macosx14.0"

echo "Building release binaries for ${TRIPLE}..."
swift build -c release --triple "$TRIPLE" --product MuxFinderApp
swift build -c release --triple "$TRIPLE" --product muxfinder-launch
BIN="$(swift build -c release --triple "$TRIPLE" --show-bin-path)"

for binary in MuxFinderApp muxfinder-launch; do
  archs="$(lipo -archs "$BIN/$binary")"
  if [ "$archs" != "arm64" ]; then
    echo "error: $binary is built for '$archs', expected arm64" >&2
    exit 1
  fi
done

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MuxFinderApp" "$APP/Contents/MacOS/muxFinder"
cp "$BIN/muxfinder-launch" "$APP/Contents/MacOS/muxfinder-launch"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>muxFinder</string>
  <key>CFBundleExecutable</key>
  <string>muxFinder</string>
  <key>CFBundleIdentifier</key>
  <string>cc.carpio.muxfinder</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>muxFinder</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>muxFinder asks iTerm2 for access to its Python API, so it can open your tmux sessions in iTerm2.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" > /dev/null

cat > "$ENTITLEMENTS" <<'ENTITLEMENTS_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
</dict>
</plist>
ENTITLEMENTS_PLIST
plutil -lint "$ENTITLEMENTS" > /dev/null

# The first "Apple Development" identity is chosen by its SHA-1 hash, which codesign takes as
# is: a name with non-ASCII letters may not match the way security prints it.
if [ -n "${MUXFINDER_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$MUXFINDER_SIGN_IDENTITY"
  IDENTITY_NAME="$MUXFINDER_SIGN_IDENTITY"
else
  FOUND="$(security find-identity -v -p codesigning | awk '/"Apple Development: / { print; exit }')"
  IDENTITY="$(printf '%s\n' "$FOUND" | awk '{ print $2 }')"
  IDENTITY_NAME="$(printf '%s\n' "$FOUND" | awk -F'"' '{ print $2 }')"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  IDENTITY_NAME="ad hoc"
  echo "warning: no \"Apple Development\" signing identity found; signing ad hoc." >&2
  echo "warning: macOS permission grants (Automation for iTerm2) reset on every ad hoc build." >&2
fi

echo "Signing with: $IDENTITY_NAME"
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" \
  "$APP/Contents/MacOS/muxfinder-launch"
codesign --force --timestamp=none --options runtime --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP (signed for development, not notarized)."
