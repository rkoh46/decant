# Decant for Windows

The Windows build of Decant lives here: a WinUI 3 app (C#, .NET 9, Windows App SDK) with the same engine logic as
the Mac app, talking to the phone through the libimobiledevice command-line tools.

- `Decant\` the app. `Engine\` is the part that knows about phones (lockdown keys, AFC and house_arrest through
  the library, installation_proxy for apps, SpringBoard icons, offload with size verification, backups and their
  browser, firmware signing and SHSH blobs, device tools, demo data); `Views\` the seven tab pages.
- `build.ps1` builds it with the .NET SDK. Visual Studio is not required; the Windows App SDK comes from NuGet.
- Set `DECANT_DEMO=1` to run with the sample iPhone, `DECANT_TAB=photos|apps|files|backup|firmware|tools` to open a
  tab (`DECANT_TOOL=<tool>` picks a tool on the Tools tab, `DECANT_SELECT=backup:<n>` a backup), `DECANT_WINDOW=WxH`
  to size the window, `DECANT_LOG=<file>` to move the log.

What it needs on the PC: the **Apple Devices** app (or iTunes) for Apple's USB driver and the Apple Mobile Device
Service, and libimobiledevice in a `Tools` folder next to `Decant.exe` (or `%LOCALAPPDATA%\Decant\Tools`): the
tools `idevice_id`, `ideviceinfo`, `idevicediagnostics`, `idevicename`, `idevicebackup2`, `idevicepair`,
`idevicesyslog`, `idevicecrashreport`, `idevicescreenshot` and `ideviceenterrecovery`, plus `imobiledevice-1.0.dll`,
`plist-2.0.dll` and the DLLs they need. The camera roll, app list, app documents, ringtones and icons go through the
library directly (`Engine\Afc.cs`, `InstallProxy.cs`, `SpringBoard.cs`), not helper processes. `irecovery.exe` and
`idevicerestore.exe` are optional: without them the Firmware tab's mode check, Update and Restore stay disabled.
`build.ps1` stages all of that from a vcpkg install of `libimobiledevice[tools]` when one is present
(`C:\vcpkg\installed\<arch>-windows`, or `VCPKG_INSTALLED`).

Screenshots for the README come from `DECANT_DEMO=1 DECANT_SHOT=<file.png>` with `DECANT_TAB` per tab: the window is laid out at the `DECANT_WINDOW` size and rendered to the file, which works on a tiny
virtual display too.

Status: all seven tabs build and run with the sample phone. Not yet tried with a real iPhone over USB, so every
phone path (lockdown, AFC, installation_proxy, house_arrest, mobilebackup2 through idevicebackup2, the TSS request)
is written from the Mac app and the library's API and needs a first test on hardware. A WinUI trap met on the way:
two stacked TextBlocks inside a ListView item template flipped the whole window to the light theme; one TextBlock
with Runs does not.
