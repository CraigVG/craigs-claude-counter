#!/usr/bin/env bash
# Build, sign (Developer ID + hardened runtime), notarize and staple the macOS
# app + widget, then package it in a DMG that is itself signed, notarized and
# stapled. Prints the DMG's SHA-256 for the Homebrew cask.
#
# Signing identity:
#   DEVID_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)". Optional
#                   when the keychain holds exactly one Developer ID Application
#                   identity (see: security find-identity -v -p codesigning).
#
# Notarization credentials, one of:
#   APPLE_API_KEY, APPLE_API_KEY_ID, APPLE_API_ISSUER
#                   an App Store Connect API key (APPLE_API_KEY is the path to the .p8)
#   NOTARY_PROFILE  a notarytool keychain profile, stored once with
#                     xcrun notarytool store-credentials <name> \
#                       --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
#   NOTARY_ENV      optional file sourced first, e.g. one that exports the API key variables
#
# Releases since v1.2.0 use the DrillerDB, LLC Developer ID and its API key:
#   NOTARY_ENV=~/.config/drillerdb-signing/notarize.env scripts/release-macos.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../macos"

if [ -n "${NOTARY_ENV:-}" ]; then
  # shellcheck disable=SC1090
  source "$NOTARY_ENV"
fi

if [ -z "${DEVID_IDENTITY:-}" ]; then
  ids="$(security find-identity -v -p codesigning | grep -oE '"Developer ID Application: [^"]+"' | tr -d '"' | sort -u || true)"
  if [ "$(printf '%s\n' "$ids" | grep -c . || true)" != 1 ]; then
    echo "Set DEVID_IDENTITY. Developer ID Application identities in the keychain:" >&2
    printf '  %s\n' "${ids:-(none)}" >&2
    exit 1
  fi
  DEVID_IDENTITY="$ids"
fi
TEAMID="$(printf '%s' "$DEVID_IDENTITY" | grep -oE '[A-Z0-9]{10}' | tail -1)"

if [ -n "${APPLE_API_KEY:-}" ]; then
  : "${APPLE_API_KEY_ID:?APPLE_API_KEY is set, so APPLE_API_KEY_ID is needed too}"
  : "${APPLE_API_ISSUER:?APPLE_API_KEY is set, so APPLE_API_ISSUER is needed too}"
  NOTARY_AUTH=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  echo "Set APPLE_API_KEY, APPLE_API_KEY_ID and APPLE_API_ISSUER (or NOTARY_ENV), or NOTARY_PROFILE." >&2
  exit 1
fi

# Submit a file for notarization and wait. Exits with Apple's log unless the
# submission is Accepted (notarytool's own exit status does not say).
notarize() {
  local out id
  out="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait 2>&1)" || true
  printf '%s\n' "$out" | grep -E '^\s*(id|status):' | tail -2 || true
  if ! printf '%s\n' "$out" | grep -qE '^\s*status: Accepted'; then
    echo "notarization of $1 was not accepted" >&2
    id="$(printf '%s\n' "$out" | grep -oE 'id: [0-9a-f-]{36}' | head -1 | cut -d' ' -f2 || true)"
    if [ -n "$id" ]; then xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true; else printf '%s\n' "$out" >&2; fi
    exit 1
  fi
}

echo "==> [1/8] generating Xcode project"
xcodegen generate >/dev/null

echo "==> [2/8] building + signing Release as $DEVID_IDENTITY"
rm -rf build
mkdir -p build
if ! xcodebuild -project CraigsClaudeCounter.xcodeproj -scheme CraigsClaudeCounter \
  -configuration Release -derivedDataPath build -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVID_IDENTITY" DEVELOPMENT_TEAM="$TEAMID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build >build/xcodebuild.log 2>&1; then
  grep -E "error:" build/xcodebuild.log | head -20 >&2 || true
  echo "build failed; full log: macos/build/xcodebuild.log" >&2
  exit 1
fi

APP="build/Build/Products/Release/CraigsClaudeCounter.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "==> [3/8] verifying signature (v$VERSION)"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> [4/8] notarizing the app (a few minutes)"
ZIP="build/CraigsClaudeCounter.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"

echo "==> [5/8] stapling the app"
xcrun stapler staple "$APP"

echo "==> [6/8] packaging the stapled app into a signed DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/CraigsClaudeCounter.dmg"
rm -f "$DMG"
if ! hdiutil create -volname "Craig's Claude Counter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >build/hdiutil.log 2>&1; then
  cat build/hdiutil.log >&2
  exit 1
fi
codesign --sign "$DEVID_IDENTITY" --timestamp "$DMG"

echo "==> [7/8] notarizing the DMG (a few minutes)"
notarize "$DMG"

echo "==> [8/8] stapling the DMG and checking Gatekeeper"
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"
spctl -a -vv "$APP"

echo
echo "Notarized v$VERSION DMG ready:"
echo "  $(pwd)/$DMG"
shasum -a 256 "$DMG"
echo
echo "Next: put v$VERSION and that sha256 in packaging/homebrew/craigs-claude-counter.rb and the"
echo "tap's Casks/craigs-claude-counter.rb, then: gh release create v$VERSION macos/$DMG"
