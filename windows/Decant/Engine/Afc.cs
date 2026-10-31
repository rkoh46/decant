// The phone's file service (AFC) through libimobiledevice's own library rather than a helper process per call:
// one session lists the camera roll, fetches thumbnails and copies files. Only what Decant needs is bound.
using System.Runtime.InteropServices;
using System.Text;

namespace Decant.Engine;

public sealed class Afc : IDisposable
{
    const string Lib = "imobiledevice-1.0";
    static bool resolverSet;

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int idevice_new(out IntPtr device, [MarshalAs(UnmanagedType.LPStr)] string? udid);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int idevice_free(IntPtr device);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lockdownd_client_new_with_handshake(IntPtr device, out IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string label);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lockdownd_client_free(IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lockdownd_start_service(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string identifier, out IntPtr service);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lockdownd_service_descriptor_free(IntPtr service);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_client_new(IntPtr device, IntPtr service, out IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_client_free(IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_read_directory(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path, out IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_get_file_info(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path, out IntPtr info);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_dictionary_free(IntPtr dict);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_file_open(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path, int mode, out ulong handle);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_file_read(IntPtr client, ulong handle, byte[] data, uint length, out uint read);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_file_close(IntPtr client, ulong handle);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_remove_path(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path);

    IntPtr device, lockdown, service, client;

    /// Points the runtime at the Tools folder next to the app (or %LOCALAPPDATA%\Decant\Tools) for the native DLLs.
    static void EnsureResolver()
    {
        if (resolverSet) return;
        resolverSet = true;
        NativeLibrary.SetDllImportResolver(typeof(Afc).Assembly, (name, asm, path) =>
        {
            if (!name.StartsWith("imobiledevice")) return IntPtr.Zero;
            foreach (var dir in Tools.ToolDirs)
            {
                var p = Path.Combine(dir, "imobiledevice-1.0.dll");
                if (File.Exists(p) && NativeLibrary.TryLoad(p, out var h)) return h;
            }
            return IntPtr.Zero;
        });
    }

    public static bool LibraryPresent => Tools.ToolDirs.Any(d => File.Exists(Path.Combine(d, "imobiledevice-1.0.dll")));

    public static Afc? Open(string udid, out string? error)
    {
        EnsureResolver();
        var a = new Afc();
        error = null;
        try
        {
            if (idevice_new(out a.device, udid) != 0) { error = "the phone is not reachable"; return null; }
            if (lockdownd_client_new_with_handshake(a.device, out a.lockdown, "Decant") != 0) { error = "lockdown refused (locked, or not trusted)"; a.Dispose(); return null; }
            if (lockdownd_start_service(a.lockdown, "com.apple.afc", out a.service) != 0) { error = "the file service did not start"; a.Dispose(); return null; }
            if (afc_client_new(a.device, a.service, out a.client) != 0) { error = "AFC refused the connection"; a.Dispose(); return null; }
            return a;
        }
        catch (DllNotFoundException) { error = "imobiledevice-1.0.dll not found"; a.Dispose(); return null; }
        catch (Exception e) { error = e.Message; a.Dispose(); return null; }
    }

    static List<string> ReadStringList(IntPtr list)
    {
        var r = new List<string>();
        if (list == IntPtr.Zero) return r;
        for (int i = 0; ; i++)
        {
            var p = Marshal.ReadIntPtr(list, i * IntPtr.Size);
            if (p == IntPtr.Zero) break;
            r.Add(Marshal.PtrToStringUTF8(p) ?? "");
        }
        return r;
    }

    public List<string> List(string path)
    {
        if (afc_read_directory(client, path, out var list) != 0) return new List<string>();
        var r = ReadStringList(list).Where(n => n != "." && n != "..").ToList();
        afc_dictionary_free(list);
        return r;
    }

    public sealed record Info(long Size, bool IsDirectory, DateTime? Modified);

    public Info? Stat(string path)
    {
        if (afc_get_file_info(client, path, out var info) != 0) return null;
        var kv = ReadStringList(info);
        afc_dictionary_free(info);
        long size = 0; bool dir = false; DateTime? mtime = null;
        for (int i = 0; i + 1 < kv.Count; i += 2)
        {
            switch (kv[i])
            {
                case "st_size": long.TryParse(kv[i + 1], out size); break;
                case "st_ifmt": dir = kv[i + 1] == "S_IFDIR"; break;
                case "st_mtime": if (long.TryParse(kv[i + 1], out var ns)) mtime = DateTimeOffset.FromUnixTimeMilliseconds(ns / 1_000_000).LocalDateTime; break;
            }
        }
        return new Info(size, dir, mtime);
    }

    /// Copies a file from the phone; returns the byte count, or -1 with `error` set.
    public long Download(string remote, string local, out string? error, CancellationToken ct = default)
    {
        error = null;
        if (afc_file_open(client, remote, 1, out var h) != 0) { error = "could not open on the phone"; return -1; }
        try
        {
            using var f = File.Create(local);
            var buf = new byte[1 << 20];
            long total = 0;
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                if (afc_file_read(client, h, buf, (uint)buf.Length, out var n) != 0) { error = "read failed"; return -1; }
                if (n == 0) break;
                f.Write(buf, 0, (int)n);
                total += n;
            }
            return total;
        }
        finally { afc_file_close(client, h); }
    }

    public bool Remove(string path) => afc_remove_path(client, path) == 0;

    public void Dispose()
    {
        if (client != IntPtr.Zero) { afc_client_free(client); client = IntPtr.Zero; }
        if (service != IntPtr.Zero) { lockdownd_service_descriptor_free(service); service = IntPtr.Zero; }
        if (lockdown != IntPtr.Zero) { lockdownd_client_free(lockdown); lockdown = IntPtr.Zero; }
        if (device != IntPtr.Zero) { idevice_free(device); device = IntPtr.Zero; }
    }
}
