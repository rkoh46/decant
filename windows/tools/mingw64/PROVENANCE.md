# Restore tools for Windows (x86_64, MinGW)

idevicerestore and irecovery do not build with the Microsoft compiler, so these are the Windows binaries the
libimobiledevice project builds itself on GitHub Actions (MSYS2 MINGW64, job `build-windows (MINGW64, x86_64)`),
downloaded unchanged on 2026-11-01 with `gh run download -R libimobiledevice/<repo> <run> -n <repo>-latest_x86_64-mingw64`.
`build.ps1` stages the folder into `Tools\` next to `Decant.exe`. They are 64-bit x86 programs; on an ARM PC
Windows runs them under its x86 emulation.

| File | Repository | Run | Commit |
|---|---|---|---|
| idevicerestore.exe | libimobiledevice/idevicerestore | 41271320701 | f61b7f27 |
| irecovery.exe, libirecovery-1.0.dll | libimobiledevice/libirecovery | 41274785244 | dc2e4c26 |
| libimobiledevice-1.0.dll | libimobiledevice/libimobiledevice | 41257288865 | fa0f7919 |
| libplist-2.0.dll | libimobiledevice/libplist | 41277164809 | fe3dc34d |
| libusbmuxd-2.0.dll | libimobiledevice/libusbmuxd | 41269761588 | 93eb168b |
| libimobiledevice-glue-1.0.dll | libimobiledevice/libimobiledevice-glue | 41270850121 | 10ddafa1 |
| libtatsu.dll | libimobiledevice/libtatsu | 41274979353 | e7d6ad13 |
| libssl-3-x64.dll, libcrypto-3-x64.dll | MSYS2 package mingw-w64-x86_64-openssl 3.6.5-1 (repo.msys2.org) | | |

SHA-256:

```
5aec02173c2b7a763653b5f1b6753fbc467b44b4206c4aa5df37dc6e213b2874  idevicerestore.exe
a13989a69638b9f52a63a57fd2f4b02373eda336ad031c93b788e9d7178f7678  irecovery.exe
26c5c4804d14049dc50e7d1a7ba5fd479c1bcee3ae5c3942a7f069f5159a4745  libcrypto-3-x64.dll
bc248655d4ba0a6c19c0fa98ab83f2320852d5248ae8b51da9366e849a8a071e  libimobiledevice-1.0.dll
6ce05d2dcca06f9e9c42aaaedcbdb621e539feb2be49c1c432ee236aa86cd626  libimobiledevice-glue-1.0.dll
de07d2e5198cc0cf6aedd5e8b3f36ff5f6ba113963c6d511853083c22e66594e  libirecovery-1.0.dll
a4efe0cec6c644a4c43e35cb0741a66a5aa89f3dd27b19ca638b484dd53150ce  libplist-2.0.dll
a3ddb63a654e05844cf59d463c9557eed7ae675d59fd2c47f3415f5e1fc067f5  libssl-3-x64.dll
6356fc9e4c82d6a09b6defb772487ea9a1c9c9189c36db9513ca3228e913d2d3  libtatsu.dll
a36be3483ce072b379dd5f5a9e80d1a8d86cf55f64088a07c4f70218704204fd  libusbmuxd-2.0.dll
```

Licences: idevicerestore and irecovery GPL-3.0 (the executables; Decant runs them as separate processes);
libirecovery, libimobiledevice, libusbmuxd, libimobiledevice-glue, libplist, libtatsu LGPL-2.1; OpenSSL Apache-2.0.
The texts are in `windows\THIRD-PARTY-NOTICES.md`, which `build.ps1` copies next to the exe.

On Windows libirecovery talks to a phone in recovery or DFU mode through Apple's own USB driver (SetupAPI), so
nothing has to be replaced with Zadig or WinUSB. The Apple Devices app (or iTunes) must be installed and its
Apple Mobile Device Service running; Decant checks that on the Firmware tab.
