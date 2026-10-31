# Decant for Windows

The Windows build of Decant lives here: a WinUI 3 app (C#, .NET 9, Windows App SDK) with the same engine logic as
the Mac app, talking to the phone through the libimobiledevice command-line tools.

- `Decant\` the app. `Engine\` is the part that knows about phones (lockdown keys, AFC listings, offload
  with size verification, demo data); `Views\` the Device and Photos pages.
- `build.ps1` builds it with the .NET SDK. Visual Studio is not required; the Windows App SDK comes from NuGet.
- Set `DECANT_DEMO=1` to run with the sample iPhone, `DECANT_TAB=photos` to open the Photos tab, `DECANT_WINDOW=WxH`
  to size the window.

What it needs on the PC: the **Apple Devices** app (or iTunes) for Apple's USB driver and the Apple Mobile Device
Service, and libimobiledevice in a `Tools` folder next to `Decant.exe` (or `%LOCALAPPDATA%\Decant\Tools`): the
tools `idevice_id`, `ideviceinfo`, `idevicediagnostics` and `idevicename`, plus `imobiledevice-1.0.dll` and the
DLLs it needs. The camera roll is read through the library directly (`Engine\Afc.cs`), not a helper process.
`build.ps1` stages all of that from a vcpkg install of `libimobiledevice[tools]` when one is present
(`C:\vcpkg\installed\<arch>-windows`, or `VCPKG_INSTALLED`).

Screenshots for the README come from `DECANT_DEMO=1 DECANT_SHOT=<file.png>` (with `DECANT_TAB=photos` for the
second one): the window is laid out at the `DECANT_WINDOW` size and rendered to the file, which works on a tiny
virtual display too.

Status: builds and runs with the sample phone. Not yet tried with a real iPhone over USB, so the lockdown and AFC
paths are written from the Mac app and the library's API and need a first test on hardware.
