// Jailbroken or not, the way 3uTools reports it: a stock iPhone never carries a package manager or a jailbreak's
// own app, so the user app list from installation_proxy tells. Mirrors `Jailbreak` in Sources/Device.swift.
namespace Decant.Engine;

public static class Jailbreak
{
    static readonly (string Id, string Name)[] Known =
    {
        ("com.saurik.Cydia", "Cydia"), ("org.coolstar.SileoStore", "Sileo"), ("org.coolstar.SileoNightly", "Sileo"),
        ("xyz.willy.Zebra", "Zebra"), ("com.opa334.Dopamine", "Dopamine"), ("org.coolstar.taurine", "Taurine"),
        ("org.coolstar.odyssey", "Odyssey"), ("science.xnu.undecimus", "unc0ver"), ("com.electrateam.chimera", "Chimera"),
        ("com.coolstar.electra", "Electra"), ("com.palera1n.loader", "palera1n"), ("org.palera1n.palera1n", "palera1n"),
    };
    static readonly (string Part, string Name)[] Fragments = { ("palera1n", "palera1n"), ("checkra1n", "checkra1n"), ("cydia", "Cydia") };

    /// The jailbreak found among the bundle ids, or "" for none.
    public static string NameIn(IEnumerable<string> ids)
    {
        foreach (var id in ids)
        {
            foreach (var k in Known) if (string.Equals(k.Id, id, StringComparison.OrdinalIgnoreCase)) return k.Name;
            var low = id.ToLowerInvariant();
            foreach (var f in Fragments) if (low.Contains(f.Part)) return f.Name;
        }
        return "";
    }

    /// null when the app list could not be read (not paired, library missing).
    public static string? Detect(string udid)
    {
        using var ip = InstallProxy.Open(udid, out _);
        if (ip == null) return null;
        var ids = ip.Browse(false, "CFBundleIdentifier").Select(d => Plist.Str(d.GetValueOrDefault("CFBundleIdentifier"))).Where(s => s.Length > 0);
        return NameIn(ids);
    }
}
