// What a restore needs on this PC besides the bundled tools: Apple's USB driver from the Apple Devices app (or iTunes). libirecovery on Windows reaches a phone in recovery or DFU mode through
// that driver, so no WinUSB/Zadig step exists; this is the one thing the user may have to install.

namespace Decant.Engine;

public static class Requirements
{
    public enum ServiceState { Present, Missing, Unknown }

    static ServiceState? cached; static DateTime cachedAt;

    /// Apple's USB driver (usbaapl64) is installed by both the Apple Devices app from the Store and iTunes; the Store app
    /// has no classic "Apple Mobile Device Service", its helper starts on demand, so the driver store is the thing to check.
    public static ServiceState AppleDriver()
    {
        if (cached != null && (DateTime.Now - cachedAt).TotalSeconds < 15) return cached.Value;
        var state = Query();
        cached = state; cachedAt = DateTime.Now;
        return state;
    }

    static ServiceState Query()
    {
        try
        {
            var store = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "DriverStore", "FileRepository");
            if (Directory.Exists(store) && Directory.EnumerateDirectories(store, "usbaapl*").Any()) return ServiceState.Present;
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages");
            if (key != null && key.GetSubKeyNames().Any(n => n.StartsWith("AppleInc.AppleDevices", StringComparison.OrdinalIgnoreCase) || n.StartsWith("AppleInc.iTunes", StringComparison.OrdinalIgnoreCase)))
                return ServiceState.Present;
            return ServiceState.Missing;
        }
        catch { return ServiceState.Unknown; }
    }

    /// Null when a restore can run; otherwise the one sentence that says what is missing.
    public static string? RestoreBlocker()
    {
        if (Session.Demo) return null;
        if (!Tools.Has("idevicerestore")) return "idevicerestore.exe is not in the Tools folder";
        if (!Tools.Has("irecovery")) return "irecovery.exe is not in the Tools folder";
        return AppleDriver() == ServiceState.Missing ? "Install the Apple Devices app (Microsoft Store) for Apple's USB driver" : null;
    }

}
