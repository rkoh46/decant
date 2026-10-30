# Decant

An iOS toolkit for the Mac. Plug in an iPhone and see what it is (model, iOS version, battery health, storage),
copy or move its photos and videos onto any drive with each file verified before anything is deleted, and keep
the phone itself in hand: restart, shut down, rename. Backups, SHSH blobs, firmware restores, apps and files are
on the [roadmap](ROADMAP.md).

Apple Silicon, macOS 15 or later. Native SwiftUI, no Electron, no accounts, nothing leaves your Mac.

## Install

Download `Decant-<version>.dmg` from the latest release, drag Decant to Applications, right-click → Open the
first time (the app is not notarized).

Device details come from [libimobiledevice](https://libimobiledevice.org). Until it ships inside the app:

```sh
brew install libimobiledevice
```

Without it the Photos tab still works; the Device tab shows only what the camera connection reports.

## Use

1. Connect the iPhone over USB, unlock it and tap **Trust** if asked.
2. **Device** shows the phone. **Photos** lists the camera roll.
3. Choose a destination folder, then **Copy to Mac**, or turn on **Delete after import** and **Move**. Every
   file is checked against the phone's size before it is deleted; nothing is removed on a failed copy.

## Build from source

```sh
./build.sh install      # needs Xcode (SwiftUI macros), installs /Applications/Decant.app
./release.sh 1.0.0      # Apple Silicon DMG in dist/
```

Design rules for contributors are in [DESIGN.md](DESIGN.md).

## Licence

MIT. Decant uses the libimobiledevice tools under the LGPL; see THIRD-PARTY-NOTICES.md once they are bundled.
