#!/bin/bash
# Build Decant.app and (optionally) install it to /Applications.
# Usage:
#   ./build.sh            # build Decant.app in this dir
#   ./build.sh install    # build, then copy to /Applications/Decant.app
#   ./build.sh run        # build, then launch the local copy
set -euo pipefail
cd "$(dirname "$0")"

BUILD="Decant.app"
# SwiftUI's @State is a compiler macro whose plugin only ships with Xcode, not the Command Line Tools.
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

build() {
  rm -rf "$BUILD"
  mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
  echo ">> building app binary"
  swiftc -O -parse-as-library -o "$BUILD/Contents/MacOS/Decant" Sources/*.swift \
    -framework SwiftUI -framework AppKit -framework ImageCaptureCore -framework AVKit
  if [ ! -f Decant.icns ]; then
    echo ">> rendering icon"
    rm -rf Decant.iconset && mkdir Decant.iconset
    swift tools/make_icon.swift Decant.iconset
    iconutil -c icns Decant.iconset -o Decant.icns
    rm -rf Decant.iconset
  fi
  cp Info.plist "$BUILD/Contents/"
  cp Decant.icns "$BUILD/Contents/Resources/"
  codesign --force -s - "$BUILD"
  echo ">> built $BUILD"
}

build
case "${1:-}" in
  install)
    pkill -x Decant 2>/dev/null || true
    rm -rf /Applications/Decant.app
    cp -R "$BUILD" /Applications/Decant.app
    codesign --force -s - /Applications/Decant.app
    echo ">> installed /Applications/Decant.app"
    ;;
  run)
    pkill -x Decant 2>/dev/null || true
    open "$BUILD"
    ;;
esac
