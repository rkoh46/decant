// A small XML property-list reader for what ideviceinfo -x and idevicediagnostics print.
using System.Globalization;
using System.Xml;
using System.Xml.Linq;

namespace Decant.Engine;

public static class Plist
{
    public static Dictionary<string, object?>? Parse(string xml)
    {
        try
        {
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null };
            using var reader = XmlReader.Create(new StringReader(xml), settings);
            var doc = XDocument.Load(reader);
            var root = doc.Root?.Elements().FirstOrDefault();
            return root == null ? null : Value(root) as Dictionary<string, object?>;
        }
        catch { return null; }
    }

    static object? Value(XElement e)
    {
        switch (e.Name.LocalName)
        {
            case "dict":
                var d = new Dictionary<string, object?>();
                var kids = e.Elements().ToList();
                for (int i = 0; i + 1 < kids.Count; i += 2) d[kids[i].Value] = Value(kids[i + 1]);
                return d;
            case "array": return e.Elements().Select(Value).ToList();
            case "string": return e.Value;
            case "integer": return long.TryParse(e.Value, out var l) ? l : null;
            case "real": return double.TryParse(e.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var r) ? r : null;
            case "true": return true;
            case "false": return false;
            case "date": return DateTime.TryParse(e.Value, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var dt) ? dt : null;
            case "data": try { return Convert.FromBase64String(e.Value.Trim()); } catch { return null; }
            default: return null;
        }
    }

    /// First value for `key` anywhere in the tree (ioregentry output nests the battery under several dictionaries).
    public static object? Find(object? node, string key)
    {
        switch (node)
        {
            case Dictionary<string, object?> d:
                if (d.TryGetValue(key, out var v)) return v;
                foreach (var kv in d) { var r = Find(kv.Value, key); if (r != null) return r; }
                break;
            case List<object?> l:
                foreach (var x in l) { var r = Find(x, key); if (r != null) return r; }
                break;
        }
        return null;
    }

    public static long? Long(object? v) => v switch { long l => l, double d => (long)d, bool b => b ? 1 : 0, string s when long.TryParse(s, out var l) => l, _ => null };
    public static string Str(object? v) => v switch { string s => s, byte[] b => Convert.ToHexString(b).ToLowerInvariant(), null => "", _ => v.ToString() ?? "" };
}
