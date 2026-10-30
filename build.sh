#!/bin/bash
# Build Offload.app and (optionally) install it to /Applications.
# Usage:
#   ./build.sh            # build Offload.app in this dir
#   ./build.sh install    # build, then copy to /Applications/Offload.app
#   ./build.sh run        # build, then launch the local copy
set -euo pipefail
cd "$(dirname "$0")"

BUILD="Offload.app"
# SwiftUI's @State is a compiler macro whose plugin only ships with Xcode, not the Command Line Tools.
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

build() {
  rm -rf "$BUILD"
  mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
  echo ">> building app binary"
  swiftc -O -parse-as-library -o "$BUILD/Contents/MacOS/Offload" Sources/*.swift \
    -framework SwiftUI -framework AppKit -framework ImageCaptureCore
  if [ ! -f Offload.icns ]; then
    echo ">> rendering icon"
    rm -rf Offload.iconset && mkdir Offload.iconset
    swift tools/make_icon.swift Offload.iconset
    iconutil -c icns Offload.iconset -o Offload.icns
    rm -rf Offload.iconset
  fi
  cp Info.plist "$BUILD/Contents/"
  cp Offload.icns "$BUILD/Contents/Resources/"
  codesign --force -s - "$BUILD"
  echo ">> built $BUILD"
}

build
case "${1:-}" in
  install)
    pkill -x Offload 2>/dev/null || true
    rm -rf /Applications/Offload.app
    cp -R "$BUILD" /Applications/Offload.app
    codesign --force -s - /Applications/Offload.app
    echo ">> installed /Applications/Offload.app"
    ;;
  run)
    pkill -x Offload 2>/dev/null || true
    open "$BUILD"
    ;;
esac
