# Decant roadmap

Decant is an iOS toolkit for the Mac: what 3uTools does, minus flashing tricks and jailbreaking, built on the
open-source libimobiledevice stack. Everything below talks to the phone over USB through Apple's own services
(lockdown, AFC, mobilebackup2, installation_proxy, diagnostics) and never writes to the device without a
confirmation in the UI.

## Done

- **Device** dashboard: model-accurate render with the camera roll on its screen, info table (iOS version, model
  and model number, region, masked serial, battery level and health, capacity), storage bar, tools (restart,
  shut down, rename), live battery/storage every 30 s.
- **Photos**: list the camera roll, thumbnails, filters, viewer (double-click), copy with size verification and
  date stamping, year/month folders, skip existing, per-item copy and delete from the context menu, test mode
  (`--test-offload N DIR`). Deletes go over USB when the phone allows it; with iCloud Photos on, iOS refuses
  that, so Decant deletes the same assets from the Mac's Photos library (PhotoKit) and iCloud removes them from
  the phone.
- **Backup & Restore** and **Firmware** tabs (see below) are built; they light up as the tools are installed.

## Next, in order

1. **Bundle the tools.** Ship `ideviceinfo`, `idevicediagnostics`, `idevicename`, `idevicebackup2`,
   `ideviceinstaller`, `afcclient`, `idevicerestore`, `irecovery`, `tsschecker` and `futurerestore` inside
   `Decant.app/Contents/Helpers` with their dylibs re-pathed (`install_name_tool`), so the public `.dmg` works
   without Homebrew. All are LGPL (2.1 or 3.0): include each licence and a THIRD-PARTY-NOTICES file. The app
   prefers the bundled copies and falls back to Homebrew's.
2. **Backup & Restore**: done in the UI; verify a real backup and restore cycle once `idevicebackup2` runs
   from the bundle.
3. **Firmware** tab: done in the UI; needs `tsschecker`, `idevicerestore`, `irecovery` and `futurerestore`
   present (vendored or bundled) to light up. Still to verify end to end on a spare device.
   - **tsschecker must be a 2026 build.** Release 444 (Oct 2025) builds iOS 27 requests without the new
     `Yonkers,SysTopPatch*` and `eUICC` components, and Apple's TSS answers `STATUS=168 An internal error
     occurred`, which tsschecker reports as "not signed". Use the CI build from `gh run download -R
     1Conan/tsschecker <run>` (macOS RELEASE artifact). Also required for A12+ devices: `--bbsnum` (baseband
     serial from lockdown, base64 → hex) and, with a generator, the matching ApNonce (SHA-384 of the generator
     bytes, first 32 bytes).
   - **SHSH blobs**: saved automatically each time the phone connects, for every version Apple is signing, with
     the generator `0x1111111111111111` (so a future restore can set a matching nonce) and the device's current
     APNonce when available. Stored per ECID under `OS_Backups/Decant/Blobs/<ECID>/`. List saved blobs, verify
     them (`tsschecker --verify`), save manually.
   - **Signing status**: which iOS versions Apple currently signs for this model (ipsw.me API), and IPSW
     downloads with checksum verification.
   - **Restore / Update to a signed version** (`idevicerestore`): erase restore, or update keeping data
     (`-u`). Enter and exit recovery, DFU detection (`irecovery`).
   - **Restore to an unsigned version with blobs** (`futurerestore`, nightly builds): needs the saved blob,
     the matching SEP and baseband from a signed IPSW (`--latest-sep --latest-baseband`) and the phone's nonce
     set to the blob's generator. On A12 and newer the generator can only be set from a jailbreak, so the UI
     shows this as a gated step: ready when a jailbreak for the installed version exists and has set the
     generator, otherwise it explains exactly what is missing instead of failing with "APNonce mismatch".
   - Every restore path shows the device, the target version, erase vs keep-data, and asks twice.
4. **Apps** (`ideviceinstaller`): list installed apps with icons and sizes, uninstall, install a signed `.ipa`
   by drag and drop. No sideload signing; that stays with AltStore/SideStore.
5. **Files** (`afcclient`): browse the media partition (DCIM, Downloads, Books) and each app's Documents folder,
   download, upload, delete, with sizes and dates.
6. **More device tools**: crash reports (`idevicecrashreport`), live system log (`idevicesyslog`) with filter,
   screenshot (`idevicescreenshot`, needs Developer Mode on iOS 17+), provisioning profiles, wallpaper.

## Not planned

Firmware flashing tricks, jailbreaking, music or ringtone sync (iTunes-only protocols), anything that needs
private Apple frameworks or a paid service.

## Release

`release.sh <version>`: Apple Silicon only (`arm64-apple-macos15.0`), builds the app, bundles the tools,
wraps a `Decant.dmg` with an Applications shortcut, and creates the GitHub release with notes.
