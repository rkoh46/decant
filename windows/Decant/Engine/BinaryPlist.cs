// Reads binary property lists (bplist00): iTunesMetadata inside app records, Manifest.plist in backups, Ringtones.plist.
// Produces the same Dictionary/List/long/double/bool/string/byte[]/DateTime shapes as Plist.Parse.
using System.Text;

namespace Decant.Engine;

public static class BinaryPlist
{
    public static bool Is(byte[] d) => d.Length > 8 && d[0] == 'b' && d[1] == 'p' && d[2] == 'l' && d[3] == 'i' && d[4] == 's' && d[5] == 't';

    /// Parses either format; returns null when the bytes are neither.
    public static object? ParseAny(byte[] d)
    {
        if (Is(d)) { try { return new BinaryPlist.Reader(d).Root(); } catch { return null; } }
        try { return Plist.Parse(Encoding.UTF8.GetString(d)); } catch { return null; }
    }

    sealed class Reader
    {
        readonly byte[] d; readonly int offSize, refSize; readonly long count, top, tableOffset;
        public Reader(byte[] data)
        {
            d = data;
            var t = d.Length - 32;
            offSize = d[t + 6]; refSize = d[t + 7];
            count = (long)Be(t + 8, 8); top = (long)Be(t + 16, 8); tableOffset = (long)Be(t + 24, 8);
        }
        ulong Be(long at, int n) { ulong v = 0; for (int i = 0; i < n; i++) v = (v << 8) | d[at + i]; return v; }
        long Offset(long idx) => (long)Be(tableOffset + idx * offSize, offSize);
        public object? Root() => Obj(top);

        object? Obj(long idx)
        {
            var at = Offset(idx);
            int marker = d[at], hi = marker >> 4, lo = marker & 0xF;
            switch (hi)
            {
                case 0x0: return lo switch { 0x8 => false, 0x9 => true, _ => null };
                case 0x1: return (long)Be(at + 1, 1 << lo);
                case 0x2: return lo == 2 ? BitConverter.Int32BitsToSingle((int)Be(at + 1, 4)) : BitConverter.Int64BitsToDouble((long)Be(at + 1, 8));
                case 0x3: return new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(BitConverter.Int64BitsToDouble((long)Be(at + 1, 8)));
                case 0x4: { var (n, s) = Len(at, lo); return d[(int)s..(int)(s + n)]; }
                case 0x5: { var (n, s) = Len(at, lo); return Encoding.ASCII.GetString(d, (int)s, (int)n); }
                case 0x6: { var (n, s) = Len(at, lo); return Encoding.BigEndianUnicode.GetString(d, (int)s, (int)(n * 2)); }
                case 0x8: return Convert.ToHexString(d, (int)at + 1, lo + 1).ToLowerInvariant();   // uid
                case 0xA: { var (n, s) = Len(at, lo); var l = new List<object?>(); for (int i = 0; i < n; i++) l.Add(Obj((long)Be(s + i * refSize, refSize))); return l; }
                case 0xD:
                {
                    var (n, s) = Len(at, lo); var r = new Dictionary<string, object?>();
                    for (int i = 0; i < n; i++)
                    {
                        var k = Obj((long)Be(s + i * refSize, refSize)) as string ?? "";
                        r[k] = Obj((long)Be(s + (n + i) * refSize, refSize));
                    }
                    return r;
                }
                default: return null;
            }
        }
        (long n, long start) Len(long at, int lo)
        {
            if (lo != 0xF) return (lo, at + 1);
            int m = d[at + 1] & 0xF; var n = (long)Be(at + 2, 1 << m);
            return (n, at + 2 + (1 << m));
        }
    }
}
