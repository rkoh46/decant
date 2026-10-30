#!/bin/bash
# Build an Apple Silicon-only Decant.dmg and (optionally) publish it as a GitHub release.
# Usage:
#   ./release.sh 1.0.0            # dist/Decant-1.0.0.dmg
#   ./release.sh 1.0.0 publish    # ...and `gh release create v1.0.0` with the DMG attached
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: release.sh <version> [publish]}"
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

sed -i '' -E "s|(<key>CFBundle(Short)?Version(String)?</key> *<string>)[^<]+|\1$VERSION|g" Info.plist
export SWIFT_TARGET=arm64-apple-macos15.0
./build.sh
tools/bundle_tools.sh Decant.app
codesign --force --deep -s - Decant.app

mkdir -p dist
STAGE=$(mktemp -d)
cp -R Decant.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Decant-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Decant" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo ">> $DMG (Apple Silicon, macOS 15 or later)"

if [ "${2:-}" = publish ]; then
  git tag -a "v$VERSION" -m "Decant $VERSION" 2>/dev/null || true
  git push --tags
  gh release create "v$VERSION" "$DMG" "$DMG.sha256" --title "Decant $VERSION" \
    --notes "Apple Silicon Macs, macOS 15 or later. Open the DMG and drag Decant to Applications. The app is not notarized: right-click it and choose Open the first time."
fi
