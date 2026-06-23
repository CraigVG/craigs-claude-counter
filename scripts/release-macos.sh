#!/usr/bin/env bash
# Build, sign (Developer ID + hardened runtime), package, notarize, and staple a
# distributable DMG of the macOS app + widget.
#
# Requires:
#   DEVID_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#                   (see: security find-identity -v -p codesigning)
#   NOTARY_PROFILE  a notarytool keychain profile name (default: ccc-notary)
#
# One-time, store notarytool credentials with an app-specific password
# (generate at appleid.apple.com > Sign-In and Security > App-Specific Passwords):
#   xcrun notarytool store-credentials ccc-notary \
#     --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../macos"
: "${DEVID_IDENTITY:?set DEVID_IDENTITY to your 'Developer ID Application: ...' identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ccc-notary}"
TEAMID="$(printf '%s' "$DEVID_IDENTITY" | grep -oE '[A-Z0-9]{10}' | tail -1)"

echo "==> [1/6] generating Xcode project"
xcodegen generate >/dev/null

echo "==> [2/6] building + signing Release (Developer ID + hardened runtime)"
rm -rf build
xcodebuild -project CraigsClaudeCounter.xcodeproj -scheme CraigsClaudeCounter \
  -configuration Release -derivedDataPath build -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVID_IDENTITY" DEVELOPMENT_TEAM="$TEAMID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

APP="build/Build/Products/Release/CraigsClaudeCounter.app"
[ -d "$APP" ] || { echo "build failed (no app)"; exit 1; }

echo "==> [3/6] verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> [4/6] packaging DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/CraigsClaudeCounter.dmg"
rm -f "$DMG"
hdiutil create -volname "Craig's Claude Counter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> [5/6] notarizing (a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> [6/6] stapling"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

echo
echo "Notarized DMG ready:"
echo "  $(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
shasum -a 256 "$DMG"
