// The installation proxy (com.apple.mobile.installation_proxy): the app list with sizes, install and uninstall.
// Options and results travel as plists; Decant builds them as XML and reads them back through LibPlist.
using System.Runtime.InteropServices;

namespace Decant.Engine;

public sealed class InstallProxy : IDisposable
{
    const string Lib = "imobiledevice-1.0";
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void StatusCb(IntPtr command, IntPtr status, IntPtr userData);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int instproxy_client_new(IntPtr device, IntPtr service, out IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int instproxy_client_free(IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int instproxy_browse(IntPtr client, IntPtr options, out IntPtr result);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int instproxy_install(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string pkgPath, IntPtr options, StatusCb? cb, IntPtr userData);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int instproxy_uninstall(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string appId, IntPtr options, StatusCb? cb, IntPtr userData);

    DeviceLink? link;
    IntPtr service, client;

    public static InstallProxy? Open(string udid, out string? error)
    {
        var link = DeviceLink.Open(udid, "Decant", out error);
        if (link == null) return null;
        var p = new InstallProxy { link = link };
        try
        {
            p.service = link.StartService("com.apple.mobile.installation_proxy");
            if (p.service == IntPtr.Zero) { error = "the app service did not start"; p.Dispose(); return null; }
            if (instproxy_client_new(link.Device, p.service, out p.client) != 0) { error = "the app service refused the connection"; p.Dispose(); return null; }
            return p;
        }
        catch (DllNotFoundException) { error = "imobiledevice-1.0.dll not found"; p.Dispose(); return null; }
        catch (Exception e) { error = e.Message; p.Dispose(); return null; }
    }

    static IntPtr Options(bool all, IEnumerable<string> attributes)
    {
        var d = new Dictionary<string, object?> { ["ApplicationType"] = all ? "Any" : "User", ["ReturnAttributes"] = attributes.Cast<object?>().ToList() };
        return LibPlist.FromXml(Plist.ToXml(d));
    }

    /// Every app record the phone returns for the attributes asked for (dictionaries keyed as the phone names them).
    public List<Dictionary<string, object?>> Browse(bool all, params string[] attributes)
    {
        var opts = Options(all, attributes);
        try
        {
            if (instproxy_browse(client, opts, out var result) != 0 || result == IntPtr.Zero) return new();
            var list = LibPlist.ToObject(result) as List<object?>;
            LibPlist.plist_free(result);
            return list?.OfType<Dictionary<string, object?>>().ToList() ?? new();
        }
        finally { LibPlist.plist_free(opts); }
    }

    /// Runs an install or uninstall, reporting status lines ("Complete", "ERROR: …", "NN%") until the phone says it is done.
    /// Returns true on Complete without an error.
    public async Task<bool> Run(bool install, string target, Action<string> line, CancellationToken ct = default)
    {
        var done = new TaskCompletionSource<bool>();
        var ok = false; string? lastError = null;
        StatusCb cb = (cmd, status, _) =>
        {
            try
            {
                if (LibPlist.ToObject(status) is not Dictionary<string, object?> s) return;
                if (s.TryGetValue("Error", out var e) && e is string es)
                {
                    var desc = s.TryGetValue("ErrorDescription", out var ed) && ed is string eds ? eds : es;
                    lastError = desc; line("ERROR: " + desc); done.TrySetResult(false); return;
                }
                if (s.TryGetValue("PercentComplete", out var p) && Plist.Long(p) is long pc) line($"{pc}%");
                if (s.TryGetValue("Status", out var st) && st is string sts)
                {
                    if (sts == "Complete") { ok = true; line("Complete"); done.TrySetResult(true); }
                    else line(sts);
                }
            }
            catch { }
        };
        var handle = GCHandle.Alloc(cb);
        try
        {
            var r = install ? instproxy_install(client, target, IntPtr.Zero, cb, IntPtr.Zero) : instproxy_uninstall(client, target, IntPtr.Zero, cb, IntPtr.Zero);
            if (r != 0) { line($"ERROR: the phone refused the request ({r})"); return false; }
            using var reg = ct.Register(() => done.TrySetResult(false));
            var finished = await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromMinutes(10), ct));
            return finished == done.Task && ok && lastError == null;
        }
        finally { handle.Free(); }
    }

    public void Dispose()
    {
        if (client != IntPtr.Zero) { instproxy_client_free(client); client = IntPtr.Zero; }
        if (service != IntPtr.Zero) { DeviceLink.lockdownd_service_descriptor_free(service); service = IntPtr.Zero; }
        link?.Dispose(); link = null;
    }
}
