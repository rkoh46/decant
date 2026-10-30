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
   - **Blob saver is Decant's own: `tools/decant-tss.c` on libtatsu.** tsschecker (release 444, Oct 2025)
     builds iOS 27 requests Apple rejects with `STATUS=168 An internal error occurred` and reports that as "not
     signed"; its CI only produces Linux builds, and blobsaver's last release is from 2023. libtatsu (the TSS
     library idevicerestore uses) is current, so decant-tss builds the request from the BuildManifest (fetched
     with HTTP range requests, 400 KB out of a 12 GB IPSW: `ManifestFetcher`), the ECID, the generator's
     ApNonce (SHA-384 of the 8 generator bytes, first 32), the baseband serial and gold-cert id from lockdown,
     and saves the response with the generator as `.shsh2`. Verified 2026-10-30: 27.2 and 27.0.1 signed.
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

## Defaults

Nothing is tied to a particular drive. Photos go to the user's Pictures folder, backups to Documents/Decant/Backups,
blobs, manifests and IPSWs to Documents/Decant (Windows: the same folders under the user profile). Every one has a
Change… button; the chosen paths are saved in the app's preferences.

## Windows

A separate app sharing the same engine pieces: decant-tss (plain C, builds on Windows), the libimobiledevice
tools (Windows builds exist), idevicerestore and futurerestore (Windows builds exist). What does not carry over:
the camera-roll reader (ImageCaptureCore) becomes AFC over `afcclient` or Windows' portable-device API; the
iCloud-delete route (PhotoKit) has no Windows equivalent, so with iCloud Photos on, deletes must go through
Apple's own apps. Windows needs Apple's USB driver, which only ships with iTunes or the Apple Devices app and
cannot be bundled. UI in WinUI 3 (C#), same DESIGN.md, with Windows wording and actions: "Show in Explorer" instead of "Show in
Finder", Explorer for folder picking and revealing, Windows' own dialogs and notifications. All testing happens
on the Mac first.

## Not planned

Firmware flashing tricks, jailbreaking, music or ringtone sync (iTunes-only protocols), anything that needs
private Apple frameworks or a paid service.

## Release

`release.sh <version>`: Apple Silicon only (`arm64-apple-macos15.0`), builds the app, bundles the tools,
wraps a `Decant.dmg` with an Applications shortcut, and creates the GitHub release with notes.
