#!/bin/bash
# Copy the libimobiledevice-family tools and their dylibs into Decant.app/Contents/Helpers so the public DMG
# works without Homebrew. Each dylib's install name is rewritten to @executable_path, and the LGPL notices are
# collected into THIRD-PARTY-NOTICES.md inside the bundle.
# Usage: tools/bundle_tools.sh Decant.app
set -euo pipefail
APP="${1:?usage: bundle_tools.sh <Decant.app>}"
HELPERS="$APP/Contents/Helpers"
mkdir -p "$HELPERS"
cd "$(dirname "$0")/.."

TOOLS=(ideviceinfo idevicediagnostics idevicename idevice_id idevicebackup2 ideviceenterrecovery afcclient idevicecrashreport)
BREW=/opt/homebrew/bin
VENDOR=vendor
copied=()

copy_tool() {   # copy_tool <path>
  local src="$1" name; name=$(basename "$src")
  [ -x "$src" ] || { echo "   skip $name (not found)"; return; }
  cp "$src" "$HELPERS/$name"; chmod 755 "$HELPERS/$name"
  copied+=("$name")
}

[ -x "$HELPERS/decant-tss" ] && copied+=(decant-tss)
for t in "${TOOLS[@]}"; do copy_tool "$BREW/$t"; done
copy_tool "$BREW/irecovery"
copy_tool "$VENDOR/idevicerestore/src/idevicerestore"
copy_tool "$VENDOR/futurerestore/futurerestore"

# Pull in every non-system dylib each binary needs, recursively, and point the binaries at the bundled copies.
bundle_libs() {
  local bin="$1" deps lib name
  # `|| true`: a leaf library with only system dependencies makes grep exit 1, which set -e would treat as fatal.
  deps=$(otool -L "$bin" | awk 'NR>1 {print $1}' | grep -E '^/opt/homebrew|^/usr/local' || true)
  for lib in $deps; do
    name=$(basename "$lib")
    if [ ! -f "$HELPERS/$name" ]; then
      cp "$lib" "$HELPERS/$name"; chmod 644 "$HELPERS/$name"
      install_name_tool -id "@executable_path/$name" "$HELPERS/$name" 2>/dev/null
      bundle_libs "$HELPERS/$name"
    fi
    install_name_tool -change "$lib" "@executable_path/$name" "$bin" 2>/dev/null
  done
}
for t in "${copied[@]}"; do bundle_libs "$HELPERS/$t"; done

# Licences: LGPL requires the text and a note of what is used.
{
  echo "# Third-party notices"
  echo
  echo "Decant bundles these tools unchanged, each under its own licence. Sources: libimobiledevice.org,"
  echo "github.com/libimobiledevice/idevicerestore, github.com/futurerestore/futurerestore; the blob saver decant-tss is Decant's own code on libtatsu."
  echo
  for t in "${copied[@]}"; do echo "- $t"; done
  echo
  for f in /opt/homebrew/opt/libimobiledevice/COPYING* /opt/homebrew/opt/libirecovery/COPYING* vendor/idevicerestore/COPYING* ; do
    [ -f "$f" ] && { echo; echo "## $(basename "$(dirname "$(dirname "$f")")")"; echo; echo '```'; cat "$f"; echo '```'; }
  done
  echo; echo "## futurerestore"; echo; echo "GNU Lesser General Public License v3.0, see https://www.gnu.org/licenses/lgpl-3.0.txt"
  echo; echo "## libtatsu, libplist"; echo; echo "GNU Lesser General Public License v2.1, see https://www.gnu.org/licenses/lgpl-2.1.txt"
} > "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"

for t in "${copied[@]}"; do codesign --force -s - "$HELPERS/$t" 2>/dev/null || true; done
for l in "$HELPERS"/*.dylib; do [ -f "$l" ] && codesign --force -s - "$l" 2>/dev/null || true; done
echo ">> bundled: ${copied[*]}"
echo ">> dylibs: $(ls "$HELPERS"/*.dylib 2>/dev/null | wc -l | tr -d ' ')"
