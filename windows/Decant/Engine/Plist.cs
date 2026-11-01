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

    /// Like Parse, but the root may be any value (ideviceinstaller prints an array of app records).
    public static object? ParseAnyRoot(string xml)
    {
        try
        {
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null };
            using var reader = XmlReader.Create(new StringReader(xml), settings);
            var root = XDocument.Load(reader).Root?.Elements().FirstOrDefault();
            return root == null ? null : Value(root);
        }
        catch { return null; }
    }

    /// Serialises the same shapes back to an XML plist (what the phone and Decant's own files read).
    public static string ToXml(object? value)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n");
        Write(sb, value, 0);
        sb.Append("</plist>\n");
        return sb.ToString();
    }

    static void Write(System.Text.StringBuilder sb, object? v, int depth)
    {
        var pad = new string('\t', depth);
        switch (v)
        {
            case Dictionary<string, object?> d:
                sb.Append(pad).Append("<dict>\n");
                foreach (var kv in d) { sb.Append(pad).Append("\t<key>").Append(Esc(kv.Key)).Append("</key>\n"); Write(sb, kv.Value, depth + 1); }
                sb.Append(pad).Append("</dict>\n"); break;
            case List<object?> l:
                sb.Append(pad).Append("<array>\n"); foreach (var x in l) Write(sb, x, depth + 1); sb.Append(pad).Append("</array>\n"); break;
            case string s: sb.Append(pad).Append("<string>").Append(Esc(s)).Append("</string>\n"); break;
            case bool b: sb.Append(pad).Append(b ? "<true/>\n" : "<false/>\n"); break;
            case long n: sb.Append(pad).Append("<integer>").Append(n).Append("</integer>\n"); break;
            case int n: sb.Append(pad).Append("<integer>").Append(n).Append("</integer>\n"); break;
            case double r: sb.Append(pad).Append("<real>").Append(r.ToString("R", CultureInfo.InvariantCulture)).Append("</real>\n"); break;
            case float r: sb.Append(pad).Append("<real>").Append(r.ToString("R", CultureInfo.InvariantCulture)).Append("</real>\n"); break;
            case DateTime dt: sb.Append(pad).Append("<date>").Append(dt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")).Append("</date>\n"); break;
            case byte[] bytes: sb.Append(pad).Append("<data>").Append(Convert.ToBase64String(bytes)).Append("</data>\n"); break;
            default: sb.Append(pad).Append("<string></string>\n"); break;
        }
    }

    static string Esc(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

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
