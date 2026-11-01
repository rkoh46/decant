// Home-screen icons through the SpringBoard service (what decant-icon does on the Mac), cached as PNGs.
using System.Runtime.InteropServices;

namespace Decant.Engine;

public sealed class SpringBoard : IDisposable
{
    const string Lib = "imobiledevice-1.0";
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sbservices_client_new(IntPtr device, IntPtr service, out IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sbservices_client_free(IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sbservices_get_icon_pngdata(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string bundleId, out IntPtr png, out ulong size);

    public static readonly string CacheDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Decant", "AppIcons");
    public static string CachePath(string bundleId) => Path.Combine(CacheDir, bundleId + ".png");

    DeviceLink? link;
    IntPtr service, client;

    public static SpringBoard? Open(string udid, out string? error)
    {
        var link = DeviceLink.Open(udid, "decant-icon", out error);
        if (link == null) return null;
        var s = new SpringBoard { link = link };
        try
        {
            s.service = link.StartService("com.apple.springboardservices");
            if (s.service == IntPtr.Zero) { error = "springboard service unavailable (is the phone unlocked?)"; s.Dispose(); return null; }
            if (sbservices_client_new(link.Device, s.service, out s.client) != 0) { error = "springboard service refused the connection"; s.Dispose(); return null; }
            return s;
        }
        catch (DllNotFoundException) { error = "imobiledevice-1.0.dll not found"; s.Dispose(); return null; }
        catch (Exception e) { error = e.Message; s.Dispose(); return null; }
    }

    /// Writes the icon PNG into the cache; false when the phone has none for that id.
    public bool Save(string bundleId)
    {
        if (sbservices_get_icon_pngdata(client, bundleId, out var png, out var size) != 0 || png == IntPtr.Zero || size == 0) return false;
        var bytes = new byte[size];
        Marshal.Copy(png, bytes, 0, (int)size);
        Directory.CreateDirectory(CacheDir);
        File.WriteAllBytes(CachePath(bundleId), bytes);
        return true;
    }

    public void Dispose()
    {
        if (client != IntPtr.Zero) { sbservices_client_free(client); client = IntPtr.Zero; }
        if (service != IntPtr.Zero) { DeviceLink.lockdownd_service_descriptor_free(service); service = IntPtr.Zero; }
        link?.Dispose(); link = null;
    }
}
