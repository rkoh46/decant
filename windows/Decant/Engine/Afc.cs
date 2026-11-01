// The phone's file service (AFC) through libimobiledevice's own library rather than a helper process per call:
// one session lists the camera roll, fetches thumbnails and copies files. Only what Decant needs is bound.
// DeviceLink is the shared connection (device + lockdown) that the other services (install proxy, SpringBoard,
// house arrest) start from.
using System.Runtime.InteropServices;
using System.Text;

namespace Decant.Engine;

/// A device handle plus a lockdown session; services are started from it.
public sealed class DeviceLink : IDisposable
{
    const string Lib = "imobiledevice-1.0";
    static bool resolverSet;

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int idevice_new(out IntPtr device, [MarshalAs(UnmanagedType.LPStr)] string? udid);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int idevice_free(IntPtr device);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lockdownd_client_new_with_handshake(IntPtr device, out IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string label);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lockdownd_client_free(IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lockdownd_start_service(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string identifier, out IntPtr service);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] public static extern int lockdownd_service_descriptor_free(IntPtr service);

    public IntPtr Device, Lockdown;

    /// Points the runtime at the Tools folder next to the app (or %LOCALAPPDATA%\Decant\Tools) for the native DLLs.
    public static void EnsureResolver()
    {
        if (resolverSet) return;
        resolverSet = true;
        LibPlist.EnsureResolver();
        NativeLibrary.SetDllImportResolver(typeof(DeviceLink).Assembly, (name, asm, path) =>
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

    public static DeviceLink? Open(string udid, string label, out string? error)
    {
        EnsureResolver();
        var d = new DeviceLink();
        error = null;
        try
        {
            if (idevice_new(out d.Device, udid) != 0) { error = "the phone is not reachable"; return null; }
            if (lockdownd_client_new_with_handshake(d.Device, out d.Lockdown, label) != 0) { error = "lockdown refused (locked, or not trusted)"; d.Dispose(); return null; }
            return d;
        }
        catch (DllNotFoundException) { error = "imobiledevice-1.0.dll not found"; d.Dispose(); return null; }
        catch (Exception e) { error = e.Message; d.Dispose(); return null; }
    }

    /// Starts a lockdown service; the caller frees the descriptor with lockdownd_service_descriptor_free.
    public IntPtr StartService(string name) => lockdownd_start_service(Lockdown, name, out var s) == 0 ? s : IntPtr.Zero;

    public void Dispose()
    {
        if (Lockdown != IntPtr.Zero) { lockdownd_client_free(Lockdown); Lockdown = IntPtr.Zero; }
        if (Device != IntPtr.Zero) { idevice_free(Device); Device = IntPtr.Zero; }
    }
}

public sealed class Afc : IDisposable
{
    const string Lib = "imobiledevice-1.0";

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_client_new(IntPtr device, IntPtr service, out IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_client_free(IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_read_directory(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path, out IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_get_file_info(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path, out IntPtr info);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_dictionary_free(IntPtr dict);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_file_open(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path, int mode, out ulong handle);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_file_read(IntPtr client, ulong handle, byte[] data, uint length, out uint read);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_file_write(IntPtr client, ulong handle, byte[] data, uint length, out uint written);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_file_close(IntPtr client, ulong handle);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_remove_path(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_make_directory(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string path);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_rename_path(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string from, [MarshalAs(UnmanagedType.LPStr)] string to);
    // house_arrest: an app's own container, vended through AFC
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int house_arrest_client_new(IntPtr device, IntPtr service, out IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int house_arrest_client_free(IntPtr client);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int house_arrest_send_command(IntPtr client, [MarshalAs(UnmanagedType.LPStr)] string command, [MarshalAs(UnmanagedType.LPStr)] string appid);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int house_arrest_get_result(IntPtr client, out IntPtr dict);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int afc_client_new_from_house_arrest_client(IntPtr hac, out IntPtr client);

    const int FopenRdOnly = 1, FopenWrOnly = 3;

    DeviceLink? link;
    IntPtr service, client, houseArrest;

    public static bool LibraryPresent => Tools.ToolDirs.Any(d => File.Exists(Path.Combine(d, "imobiledevice-1.0.dll")));

    /// The Media folder (com.apple.afc): books, DCIM, ringtones, recordings.
    public static Afc? Open(string udid, out string? error)
    {
        var link = DeviceLink.Open(udid, "Decant", out error);
        if (link == null) return null;
        var a = new Afc { link = link };
        try
        {
            a.service = link.StartService("com.apple.afc");
            if (a.service == IntPtr.Zero) { error = "the file service did not start"; a.Dispose(); return null; }
            if (afc_client_new(link.Device, a.service, out a.client) != 0) { error = "AFC refused the connection"; a.Dispose(); return null; }
            return a;
        }
        catch (DllNotFoundException) { error = "imobiledevice-1.0.dll not found"; a.Dispose(); return null; }
        catch (Exception e) { error = e.Message; a.Dispose(); return null; }
    }

    /// One app's container through house_arrest; paths are container-relative ("/Documents" is the shared part).
    public static Afc? OpenHouseArrest(string udid, string bundleId, out string? error)
    {
        var link = DeviceLink.Open(udid, "Decant", out error);
        if (link == null) return null;
        var a = new Afc { link = link };
        try
        {
            a.service = link.StartService("com.apple.mobile.house_arrest");
            if (a.service == IntPtr.Zero) { error = "the app container service did not start"; a.Dispose(); return null; }
            if (house_arrest_client_new(link.Device, a.service, out a.houseArrest) != 0) { error = "house_arrest refused the connection"; a.Dispose(); return null; }
            if (house_arrest_send_command(a.houseArrest, "VendDocuments", bundleId) != 0) { error = "the app did not open its documents"; a.Dispose(); return null; }
            if (house_arrest_get_result(a.houseArrest, out var dict) == 0 && dict != IntPtr.Zero)
            {
                var r = LibPlist.ToObject(dict) as Dictionary<string, object?>;
                LibPlist.plist_free(dict);
                if (r != null && r.TryGetValue("Error", out var e) && e is string es) { error = es == "ApplicationLookupFailed" ? "the app is not on the phone" : es; a.Dispose(); return null; }
            }
            if (afc_client_new_from_house_arrest_client(a.houseArrest, out a.client) != 0) { error = "AFC refused the app container"; a.Dispose(); return null; }
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

    public List<string> List(string path) => TryList(path) ?? new List<string>();

    /// Null when the folder cannot be read (as opposed to an empty folder).
    public List<string>? TryList(string path)
    {
        if (afc_read_directory(client, path, out var list) != 0) return null;
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
        if (afc_file_open(client, remote, FopenRdOnly, out var h) != 0) { error = "could not open on the phone"; return -1; }
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

    /// Reads a whole file into memory, or null.
    public byte[]? ReadAll(string remote)
    {
        if (afc_file_open(client, remote, FopenRdOnly, out var h) != 0) return null;
        try
        {
            using var m = new MemoryStream();
            var buf = new byte[1 << 18];
            while (true)
            {
                if (afc_file_read(client, h, buf, (uint)buf.Length, out var n) != 0) return null;
                if (n == 0) break;
                m.Write(buf, 0, (int)n);
            }
            return m.ToArray();
        }
        finally { afc_file_close(client, h); }
    }

    /// Writes bytes to a file on the phone (created or truncated); returns null, or an error.
    public string? WriteAll(string remote, byte[] data)
    {
        if (afc_file_open(client, remote, FopenWrOnly, out var h) != 0) return "could not create on the phone";
        try
        {
            int at = 0;
            while (at < data.Length)
            {
                var chunk = Math.Min(1 << 20, data.Length - at);
                var part = new byte[chunk]; Array.Copy(data, at, part, 0, chunk);
                if (afc_file_write(client, h, part, (uint)chunk, out var w) != 0 || w == 0) return "write failed";
                at += (int)w;
            }
            return null;
        }
        finally { afc_file_close(client, h); }
    }

    /// Copies a local file onto the phone; returns null, or an error.
    public string? Upload(string local, string remote, CancellationToken ct = default)
    {
        if (afc_file_open(client, remote, FopenWrOnly, out var h) != 0) return "could not create on the phone";
        try
        {
            using var f = File.OpenRead(local);
            var buf = new byte[1 << 20];
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var n = f.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                var part = n == buf.Length ? buf : buf[..n];
                if (afc_file_write(client, h, part, (uint)n, out var w) != 0 || w != n) return "write failed";
            }
            return null;
        }
        finally { afc_file_close(client, h); }
    }

    /// Copies a local file or folder (recursively) to `remote`; returns null, or the first error.
    public string? UploadTree(string local, string remote, CancellationToken ct = default)
    {
        if (Directory.Exists(local))
        {
            MakeDirectory(remote);
            foreach (var e in Directory.EnumerateFileSystemEntries(local))
            {
                var err = UploadTree(e, remote.TrimEnd('/') + "/" + Path.GetFileName(e), ct);
                if (err != null) return err;
            }
            return null;
        }
        return Upload(local, remote, ct);
    }

    /// Copies a file or folder (recursively) from the phone to `local`; returns null, or the first error.
    public string? DownloadTree(string remote, string local, CancellationToken ct = default)
    {
        var st = Stat(remote);
        if (st == null) return "not found on the phone";
        if (st.IsDirectory)
        {
            Directory.CreateDirectory(local);
            foreach (var n in List(remote))
            {
                var err = DownloadTree(remote.TrimEnd('/') + "/" + n, Path.Combine(local, n), ct);
                if (err != null) return err;
            }
            return null;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(local)!);
        return Download(remote, local, out var e, ct) < 0 ? e : null;
    }

    public bool MakeDirectory(string path) => afc_make_directory(client, path) == 0;
    public bool Rename(string from, string to) => afc_rename_path(client, from, to) == 0;
    public bool Remove(string path) => afc_remove_path(client, path) == 0;

    /// Removes a file, or a folder and everything in it.
    public bool RemoveTree(string path)
    {
        var st = Stat(path);
        if (st?.IsDirectory == true) foreach (var n in List(path)) RemoveTree(path.TrimEnd('/') + "/" + n);
        return afc_remove_path(client, path) == 0;
    }

    public void Dispose()
    {
        if (client != IntPtr.Zero) { afc_client_free(client); client = IntPtr.Zero; }
        if (houseArrest != IntPtr.Zero) { house_arrest_client_free(houseArrest); houseArrest = IntPtr.Zero; }
        if (service != IntPtr.Zero) { DeviceLink.lockdownd_service_descriptor_free(service); service = IntPtr.Zero; }
        link?.Dispose(); link = null;
    }
}
