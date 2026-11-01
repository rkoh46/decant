// Finder-style name order: case-insensitive, digit runs compared by value ("IMG_9" before "IMG_10").
using System.Globalization;

namespace Decant.Engine;

public static class Natural
{
    public static readonly Comparer<string> Comparer = Comparer<string>.Create(Compare);

    public static int Compare(string a, string b)
    {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                var na = a[si..i].TrimStart('0'); var nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length - nb.Length;
                var c = string.CompareOrdinal(na, nb);
                if (c != 0) return c;
            }
            else
            {
                var c = string.Compare(a[i].ToString(), b[j].ToString(), CultureInfo.CurrentCulture, CompareOptions.IgnoreCase);
                if (c != 0) return c;
                i++; j++;
            }
        }
        return (a.Length - i) - (b.Length - j);
    }
}
