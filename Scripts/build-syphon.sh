#!/bin/bash
# Rebuilds Frameworks/Syphon.framework from source.
#
# The framework is committed to this repository so a clone builds offline, but
# it is a third-party binary — this script reproduces it. Syphon is under the
# 3-clause BSD licence; see Frameworks/Syphon-License.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 https://github.com/Syphon/Syphon-Framework.git "$WORK/Syphon"

xcodebuild \
    -project "$WORK/Syphon/Syphon.xcodeproj" \
    -scheme Syphon \
    -configuration Release \
    -derivedDataPath "$WORK/dd" \
    ARCHS="x86_64 arm64" \
    ONLY_ACTIVE_ARCH=NO \
    build

BUILT="$WORK/dd/Build/Products/Release/Syphon.framework"
rm -rf "$ROOT/Frameworks/Syphon.framework"
cp -R "$BUILT" "$ROOT/Frameworks/Syphon.framework"
cp "$WORK/Syphon/License.txt" "$ROOT/Frameworks/Syphon-License.txt"

lipo -info "$ROOT/Frameworks/Syphon.framework/Versions/A/Syphon"
