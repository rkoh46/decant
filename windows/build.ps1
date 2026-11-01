# Builds Decant for Windows. Needs .NET SDK 9 and the Windows App SDK packages (restored from NuGet).
#   .\build.ps1            Release build for this machine's architecture into windows\dist\Decant-<arch>\
#   .\build.ps1 -Run       build, then start it (DECANT_DEMO=1 for the sample phone)
param([switch]$Run, [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }))
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $root "dist\Decant-$Arch"
dotnet build (Join-Path $root 'Decant\Decant.csproj') -c Release -r "win-$Arch" -p:Platform=$Arch -p:OutDir="$out\" --self-contained false
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# The device tools: libimobiledevice built with vcpkg (libimobiledevice[tools]) is staged into Tools\ next to the exe.
$vcpkg = if ($env:VCPKG_INSTALLED) { $env:VCPKG_INSTALLED } else { "C:\vcpkg\installed\$Arch-windows" }
if (Test-Path "$vcpkg\tools\libimobiledevice") {
  New-Item -ItemType Directory -Force "$out\Tools" | Out-Null
  Copy-Item "$vcpkg\tools\libimobiledevice\*.exe" "$out\Tools\" -Force
  Copy-Item "$vcpkg\bin\*.dll" "$out\Tools\" -Force
  "staged device tools from $vcpkg"
}
# Restores: idevicerestore and irecovery (vcpkg ports idevicerestore and libirecovery), when they were built.
foreach ($t in @('idevicerestore', 'libirecovery')) {
  if (Test-Path "$vcpkg\tools\$t") {
    New-Item -ItemType Directory -Force "$out\Tools" | Out-Null
    Copy-Item "$vcpkg\tools\$t\*.exe" "$out\Tools\" -Force
    "staged $t"
  }
}
"built $out\Decant.exe"
if ($Run) { & "$out\Decant.exe" }
