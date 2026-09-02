#!/bin/bash
# Builds a Release app and packages it as a distributable disk image.
#
# Signing follows what the machine can do. With a Developer ID certificate in
# the keychain the app is signed with it under the hardened runtime; add a
# notarytool credential profile named in NOTARY_PROFILE and the image is
# notarised and stapled as well, which is what clears Gatekeeper silently.
# With neither, the build falls back to an ad-hoc signature and macOS shows
# the "unidentified developer" warning on first launch.
#
# Create the profile once, interactively, with your own Apple ID:
#     xcrun notarytool store-credentials heatpeek \
#         --apple-id <your-apple-id> --team-id <your-team-id>
set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-heatpeek}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate

xcodebuild \
    -project HeatPeek.xcodeproj \
    -scheme HeatPeek \
    -configuration Release \
    -derivedDataPath "$STAGE/dd" \
    ARCHS="x86_64 arm64" \
    ONLY_ACTIVE_ARCH=NO \
    build

APP="$STAGE/dd/Build/Products/Release/HeatPeek.app"
[ -d "$APP" ] || { echo "build produced no app bundle" >&2; exit 1; }

# The bundle is the authority on the version, not the project file.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# The embedded framework has to be signed before the bundle that contains it.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    echo "signing as: $IDENTITY"
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
else
    echo "no Developer ID in the keychain; signing ad-hoc"
    SIGN_ARGS=(--force --sign - --timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Syphon.framework"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

notarise() {  # notarise() <file>
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

NOTARISE=false
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARISE=true
else
    echo "no notarytool profile \"$NOTARY_PROFILE\"; the build is signed but not notarised"
fi

# The app is notarised and stapled before it is packaged. A ticket on the disk
# image alone would not travel with the app once it is dragged out, leaving a
# machine that is offline on first launch unable to check it.
if $NOTARISE; then
    echo "notarising the app…"
    ditto -c -k --keepParent "$APP" "$STAGE/HeatPeek.zip"
    notarise "$STAGE/HeatPeek.zip"
    xcrun stapler staple "$APP"
fi

# Disk image layout: the app plus a link to /Applications to drag it into.
VOLUME="$STAGE/volume"
mkdir -p "$VOLUME"
cp -R "$APP" "$VOLUME/"
ln -s /Applications "$VOLUME/Applications"

mkdir -p "$DIST"
DMG="$DIST/HeatPeek-$VERSION.dmg"
rm -f "$DMG"
hdiutil create \
    -volname "HeatPeek $VERSION" \
    -srcfolder "$VOLUME" \
    -ov -format UDZO \
    "$DMG"

# The image carries a signature of its own, so Gatekeeper can assess the
# download itself rather than only what is inside it.
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
if $NOTARISE; then
    echo "notarising the image…"
    notarise "$DMG"
    xcrun stapler staple "$DMG"
fi

echo
xcrun stapler validate "$DMG" 2>&1 | tail -1
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/gatekeeper image: /' || true
shasum -a 256 "$DMG"
echo "$DMG"
