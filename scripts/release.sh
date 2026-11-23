#!/bin/bash
# Builds the signed, notarised release zip, dist/VoiceDictation-<version>.zip,
# and the Sparkle feed that offers it to installed copies, dist/appcast.xml.
# Setup (D4 and Sparkle, done once by hand) is in docs/release.md.
# Run: ./scripts/release.sh
#
# Steps: 0 checks, 1 archive, 2 export, 3 notarise, 4 staple and verify, 5 zip,
# 6 sign the zip and write the appcast. The checks run first and offline, so a
# missing setup fails before any build or upload. Building never contacts
# Apple; only step 3 does.

set -euo pipefail

cd "$(dirname "$0")/.."

# xcode-select may point at the Command Line Tools, which cannot build an app.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

IDENTITY="Developer ID Application"
NOTARY_PROFILE="voicedictation-notary"
TEAM_ID="F7DL4CTLLL"   # same as DEVELOPMENT_TEAM in project.yml

BUILD_DIR="dist/build.noindex"  # scratch: archive, export, notarisation zip, appcast; .noindex keeps Spotlight (and the App Library) from listing the exported app
ARCHIVE="$BUILD_DIR/VoiceDictation.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/VoiceDictation.app"
# The Swift packages, kept between runs. Sparkle's tools come with Sparkle's.
PACKAGES_DIR="dist/packages"
SPARKLE_BIN="$PACKAGES_DIR/artifacts/sparkle/Sparkle/bin"

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

# Sparkle. A copy built with the placeholder feed or key could never take an
# update, so stop until both are real.
FEED_URL="$(sed -n 's/^ *SUFeedURL: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml)"
PUBLIC_ED_KEY="$(sed -n 's/^ *SUPublicEDKey: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml)"
if [ -z "$FEED_URL" ] || [ -z "$PUBLIC_ED_KEY" ] || grep -qi placeholder <<<"$FEED_URL $PUBLIC_ED_KEY"; then
    cat >&2 <<MSG
SUFeedURL or SUPublicEDKey in project.yml is still a placeholder (or missing), and a
copy released with one could never take an update. Set both up once, as
docs/release.md says under "Sparkle", then run this again. Nothing was built and
nothing was sent to Apple.
MSG
    exit 1
fi

# The feed is appcast.xml in the newest GitHub release, and each release's zip
# is an asset of the release tagged v<version>.
case "$FEED_URL" in
    https://github.com/*/releases/latest/download/appcast.xml) ;;
    *)
        echo "SUFeedURL in project.yml is $FEED_URL; it must be https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml (docs/release.md). Nothing was built." >&2
        exit 1
        ;;
esac
DOWNLOAD_URL_PREFIX="${FEED_URL%/latest/download/appcast.xml}/download/v$VERSION/"

# The private key generate_keys saved, under the service and account Sparkle's
# tools use. This only looks for it; it reads no secret.
if ! security find-generic-password -s "https://sparkle-project.org" -a ed25519 >/dev/null 2>&1; then
    cat >&2 <<MSG
No Sparkle signing key in your keychain, so the update could not be signed. Make it
once with Sparkle's generate_keys, or bring it from your other Mac with
generate_keys -x and -f (docs/release.md, "Sparkle"). Nothing was built and nothing
was sent to Apple.
MSG
    exit 1
fi

# --- 1. Archive ---------------------------------------------------------------

mkdir -p dist
# A fresh build folder each run. The finished zip lives outside it, so it survives.
rm -rf "${BUILD_DIR:?}"
mkdir -p "$BUILD_DIR"

# xcodebuild writes the app's packages, Sparkle among them, into
# Package.resolved. The committed copy is SwiftPM's, without Sparkle, and it is
# the one to keep: a copy goes aside now and comes back however this ends.
cp Package.resolved "$BUILD_DIR/Package.resolved.committed"
trap 'cp "$BUILD_DIR/Package.resolved.committed" Package.resolved' EXIT

xcodegen
xcodebuild archive \
    -scheme VoiceDictation \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -archivePath "$ARCHIVE" \
    -clonedSourcePackagesDirPath "$PACKAGES_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID"

# The app must carry the public half of the key that signs its updates, or the
# copies it is installed as could never take one. generate_keys -p only prints
# the public key of the key already in the keychain (the keychain may ask
# whether it may use it).
ARCHIVED_KEY="$(plutil -extract SUPublicEDKey raw -o - "$ARCHIVE/Products/Applications/VoiceDictation.app/Contents/Info.plist")"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p)" || { echo "generate_keys -p failed: $KEYCHAIN_KEY" >&2; exit 1; }
if [ "$KEYCHAIN_KEY" != "$ARCHIVED_KEY" ]; then
    echo "The app's SUPublicEDKey is not the public half of the Sparkle key in this keychain (generate_keys -p prints that; docs/release.md, \"Sparkle\"). Nothing was sent to Apple." >&2
    exit 1
fi

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

# --- 6. Sign the zip and write the appcast (Sparkle) ---------------------------

# generate_appcast signs the zip with the Sparkle key in your keychain (the
# keychain may ask whether it may use it) and writes appcast.xml, named after
# SUFeedURL, whose download link is the zip's place in GitHub release
# v<version>. The folder is new each run, so the feed lists this release alone,
# which is all Sparkle needs.
APPCAST_DIR="$BUILD_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "$OUT" "$APPCAST_DIR/"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$APPCAST_DIR"
cp "$APPCAST_DIR/appcast.xml" dist/appcast.xml

echo "Done: $OUT and dist/appcast.xml. Publish both as GitHub release v$VERSION (docs/release.md)."
