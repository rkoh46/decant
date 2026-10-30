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
  echo ">> building decant-tss (blob saver on libtatsu)"
  mkdir -p "$BUILD/Contents/Helpers"
  clang -O2 -Wno-unused-result -o "$BUILD/Contents/Helpers/decant-tss" tools/decant-tss.c \
    -I/opt/homebrew/include -L/opt/homebrew/lib -ltatsu -lplist-2.0 -framework Security
  echo ">> building decant-icon (app icons over the SpringBoard service)"
  clang -O2 -o "$BUILD/Contents/Helpers/decant-icon" tools/decant-icon.c \
    -I/opt/homebrew/include -L/opt/homebrew/lib -limobiledevice-1.0 -lplist-2.0
  swiftc -O -parse-as-library -o "$BUILD/Contents/MacOS/Decant" Sources/*.swift \
    -framework SwiftUI -framework AppKit -framework ImageCaptureCore -framework AVKit -framework Photos
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
