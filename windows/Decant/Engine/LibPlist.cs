// The few libplist calls needed to move plist_t values between libimobiledevice and Decant's own dictionaries.
using System.Runtime.InteropServices;

namespace Decant.Engine;

public static class LibPlist
{
    const string Lib = "plist-2.0";
    static bool resolverSet;
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] public static extern void plist_to_xml(IntPtr plist, out IntPtr xml, out uint length);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] public static extern void plist_from_xml([MarshalAs(UnmanagedType.LPStr)] string xml, uint length, out IntPtr plist);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] public static extern void plist_free(IntPtr plist);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] public static extern void plist_mem_free(IntPtr ptr);

    public static void EnsureResolver()
    {
        if (resolverSet) return;
        resolverSet = true;
        NativeLibrary.SetDllImportResolver(typeof(LibPlist).Assembly, (name, asm, path) =>
        {
            if (!name.StartsWith("plist")) return IntPtr.Zero;
            foreach (var dir in Tools.ToolDirs)
            {
                var p = Path.Combine(dir, "plist-2.0.dll");
                if (File.Exists(p) && NativeLibrary.TryLoad(p, out var h)) return h;
            }
            return IntPtr.Zero;
        });
    }

    /// A plist_t as Decant's dictionary/list shapes (the node is not freed).
    public static object? ToObject(IntPtr node)
    {
        if (node == IntPtr.Zero) return null;
        plist_to_xml(node, out var xml, out var len);
        if (xml == IntPtr.Zero) return null;
        var s = Marshal.PtrToStringUTF8(xml, (int)len);
        plist_mem_free(xml);
        return Plist.ParseAnyRoot(s);
    }

    /// A new plist_t built from an XML string; the caller frees it with plist_free.
    public static IntPtr FromXml(string xml)
    {
        plist_from_xml(xml, (uint)System.Text.Encoding.UTF8.GetByteCount(xml), out var p);
        return p;
    }
}
