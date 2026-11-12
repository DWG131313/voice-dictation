#!/bin/bash
# Builds the signed, notarised release zip: dist/VoiceDictation-<version>.zip.
# Setup (D4, done once by hand) is in docs/release.md. Run: ./scripts/release.sh
#
# Steps: 0 checks, 1 archive, 2 export, 3 notarise, 4 staple and verify, 5 zip.
# The checks run first and offline, so a missing setup fails before any build
# or upload. Building never contacts Apple; only step 3 does.

set -euo pipefail

cd "$(dirname "$0")/.."

# xcode-select may point at the Command Line Tools, which cannot build an app.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

IDENTITY="Developer ID Application"
NOTARY_PROFILE="voicedictation-notary"
TEAM_ID="F7DL4CTLLL"   # same as DEVELOPMENT_TEAM in project.yml

BUILD_DIR="dist/build"          # scratch: archive, export, notarisation zip
ARCHIVE="$BUILD_DIR/VoiceDictation.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/VoiceDictation.app"

# --- 0. Checks (offline) -----------------------------------------------------

# The version comes from project.yml (CFBundleShortVersionString), the same
# place the app's Info.plist gets it from. Never hardcode it here.
VERSION="$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml)"
if [ -z "$VERSION" ]; then
    echo "Cannot read CFBundleShortVersionString from project.yml." >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY: .*($TEAM_ID)\""; then
    cat >&2 <<MSG
No "$IDENTITY" certificate for team $TEAM_ID in your keychain, so there is nothing to sign
the release with. This is setup step D4 (see docs/release.md): create the
certificate, and the notarytool profile "$NOTARY_PROFILE", once. Nothing was
built and nothing was sent to Apple.
MSG
    exit 1
fi

# notarytool has no offline way to test for a saved profile: every subcommand
# that uses one contacts Apple. So the profile (the other half of D4) is first
# used in step 3, after the build. If it is missing, step 3 stops with
# notarytool's own error; fix it per docs/release.md and run this again.

# --- 1. Archive ---------------------------------------------------------------

mkdir -p dist
# A fresh build folder each run. The finished zip lives outside it, so it survives.
rm -rf "${BUILD_DIR:?}"
mkdir -p "$BUILD_DIR"

xcodegen
xcodebuild archive \
    -scheme VoiceDictation \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID"

# --- 2. Export (Developer ID) --------------------------------------------------

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$IDENTITY</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

# --- 3. Notarise (uploads to Apple) --------------------------------------------

# ditto keeps the bundle's resource forks and symlinks; plain zip does not.
ditto -c -k --keepParent "$APP" "$BUILD_DIR/notarise.zip"
# Some notarytool versions exit 0 even when Apple rejects the build, so read
# the final status from the JSON result and stop unless it is Accepted.
if ! RESULT="$(xcrun notarytool submit "$BUILD_DIR/notarise.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"; then
    echo "$RESULT" >&2
    echo "Notarisation failed; see the message above. Nothing was released." >&2
    exit 1
fi
STATUS="$(echo "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)"
if [ "$STATUS" != "Accepted" ]; then
    echo "$RESULT" >&2
    echo "Notarisation status is \"$STATUS\", not Accepted. Nothing was released." >&2
    exit 1
fi

# --- 4. Staple and verify ------------------------------------------------------

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"

# --- 5. Zip the stapled app for distribution ------------------------------------

OUT="dist/VoiceDictation-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$OUT"
echo "Done: $OUT"
