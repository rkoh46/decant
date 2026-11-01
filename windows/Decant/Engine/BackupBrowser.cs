// Reads an iPhone backup folder: the manifest, the keybag of an encrypted backup, and the databases inside, and
// exports what people want out of one (messages, contacts, calls, notes, voice memos, Safari, WhatsApp) as plain
// files. A port of the Mac's BackupBrowser.swift. Nothing here talks to the phone or the network.
using System.Buffers.Binary;
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace Decant.Engine;

public sealed record BackupFile(string FileID, string Domain, string RelativePath, long Size, bool IsDirectory);

public sealed class BackupSummary
{
    public int Messages, Conversations, Contacts, Calls, Notes, VoiceMemos, SafariHistory, WhatsappChats, WhatsappMessages;
}

public enum BackupExport { Messages, Contacts, Calls, Notes, VoiceMemos, Safari, Whatsapp }

public static class BackupExportInfo
{
    public static string Title(this BackupExport k) => k switch
    {
        BackupExport.Messages => "Messages", BackupExport.Contacts => "Contacts", BackupExport.Calls => "Call history", BackupExport.Notes => "Notes",
        BackupExport.VoiceMemos => "Voice memos", BackupExport.Safari => "Safari history", _ => "WhatsApp",
    };
    public static readonly BackupExport[] All = { BackupExport.Messages, BackupExport.Contacts, BackupExport.Calls, BackupExport.Notes, BackupExport.VoiceMemos, BackupExport.Safari, BackupExport.Whatsapp };
}

public sealed class BackupException : Exception { public BackupException(string m) : base(m) { } }

public sealed class BackupReader : IDisposable
{
    public const string HomeDomain = "HomeDomain", MediaDomain = "MediaDomain";
    public const string NotesDomain = "AppDomainGroup-group.com.apple.notes", WhatsappDomain = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared";

    readonly string folder, scratch;
    readonly Dictionary<string, object?> manifestPlist;
    public readonly bool IsEncrypted;
    SqliteConnection? manifest;
    Dictionary<uint, byte[]> classKeys = new();
    readonly Dictionary<string, SqliteConnection?> dbCache = new();
    public bool IsUnlocked => manifest != null;

    public BackupReader(string folder)
    {
        this.folder = folder;
        var name = Path.GetFileName(folder);
        if (!File.Exists(Path.Combine(folder, "Manifest.db"))) throw new BackupException($"No Manifest.db in {name}: not an iPhone backup");
        var mp = Path.Combine(folder, "Manifest.plist");
        manifestPlist = (File.Exists(mp) ? BinaryPlist.ParseAny(File.ReadAllBytes(mp)) as Dictionary<string, object?> : null)
            ?? throw new BackupException($"No Manifest.plist in {name}: not an iPhone backup");
        IsEncrypted = manifestPlist.GetValueOrDefault("IsEncrypted") as bool? ?? false;
        scratch = Path.Combine(Path.GetTempPath(), "BackupReader-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
        if (!IsEncrypted)
        {
            // The original is opened read-only from a copy, so a WAL or lock on it never matters.
            var copy = Path.Combine(scratch, "Manifest.db");
            File.Copy(Path.Combine(folder, "Manifest.db"), copy);
            manifest = Open(copy);
        }
    }

    static SqliteConnection Open(string path)
    {
        var c = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly }.ToString());
        c.Open();
        return c;
    }

    // MARK: Encryption

    public void Unlock(string password)
    {
        if (!IsEncrypted || IsUnlocked) return;
        if (manifestPlist.GetValueOrDefault("BackupKeyBag") is not byte[] keybag || manifestPlist.GetValueOrDefault("ManifestKey") is not byte[] manifestKey || manifestKey.Length < 44)
            throw new BackupException("Manifest.plist has no keybag");
        var header = new Dictionary<string, byte[]>();
        var classes = new List<(uint cls, uint wrap, byte[] wpky)>();
        uint curCls = 0, curWrap = 0; byte[]? curWpky = null; bool inClass = false;
        int pos = 0;
        while (pos + 8 <= keybag.Length)
        {
            var tag = Encoding.ASCII.GetString(keybag, pos, 4);
            var len = (int)BinaryPrimitives.ReadUInt32BigEndian(keybag.AsSpan(pos + 4, 4));
            pos += 8;
            if (pos + len > keybag.Length) throw new BackupException("Corrupt keybag");
            var value = keybag[pos..(pos + len)];
            pos += len;
            if (tag == "UUID")
            {
                if (inClass && curWpky != null && curWpky.Length > 0) classes.Add((curCls, curWrap, curWpky));
                if (header.ContainsKey("UUID")) { inClass = true; curCls = 0; curWrap = 0; curWpky = null; }
                else header["UUID"] = value;
                continue;
            }
            if (inClass)
            {
                switch (tag)
                {
                    case "CLAS": curCls = BinaryPrimitives.ReadUInt32BigEndian(value); break;
                    case "WRAP": curWrap = BinaryPrimitives.ReadUInt32BigEndian(value); break;
                    case "WPKY": curWpky = value; break;
                }
            }
            else header[tag] = value;
        }
        if (inClass && curWpky != null && curWpky.Length > 0) classes.Add((curCls, curWrap, curWpky));
        if (!header.TryGetValue("SALT", out var salt) || !header.TryGetValue("ITER", out var iterB)) throw new BackupException("Keybag has no salt");
        var iter = (int)BinaryPrimitives.ReadUInt32BigEndian(iterB);
        byte[] key;
        if (header.TryGetValue("DPSL", out var dpsl) && header.TryGetValue("DPIC", out var dpicB))
        {
            var k1 = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), dpsl, (int)BinaryPrimitives.ReadUInt32BigEndian(dpicB), HashAlgorithmName.SHA256, 32);
            key = Rfc2898DeriveBytes.Pbkdf2(k1, salt, iter, HashAlgorithmName.SHA1, 32);
        }
        else key = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, iter, HashAlgorithmName.SHA1, 32);
        var protectedClasses = classes.Where(c => (c.wrap & 2) != 0).ToList();
        if (protectedClasses.Count == 0) throw new BackupException("Keybag has no passcode-protected classes");
        var keys = new Dictionary<uint, byte[]>();
        foreach (var c in protectedClasses) if (AesUnwrap(key, c.wpky) is byte[] k) keys[c.cls] = k;
        if (keys.Count == 0) throw new BackupException("Wrong password");
        var cls = BinaryPrimitives.ReadUInt32LittleEndian(manifestKey.AsSpan(0, 4));
        var dbKey = keys.TryGetValue(cls, out var ck) ? AesUnwrap(ck, manifestKey[4..44]) : null;
        if (dbKey == null) throw new BackupException("Wrong password");
        var raw = File.ReadAllBytes(Path.Combine(folder, "Manifest.db"));
        var plain = AesCbcZeroIv(dbKey, raw, PaddingMode.PKCS7) ?? AesCbcZeroIv(dbKey, raw, PaddingMode.None);
        if (plain == null || plain.Length < 100 || Encoding.ASCII.GetString(plain, 0, 15) != "SQLite format 3") throw new BackupException("Wrong password");
        var dbPath = Path.Combine(scratch, "Manifest.db");
        File.WriteAllBytes(dbPath, plain);
        classKeys = keys;
        manifest = Open(dbPath);
    }

    /// RFC 3394 AES key unwrap; null when the integrity check fails.
    static byte[]? AesUnwrap(byte[] kek, byte[] wrapped)
    {
        if (wrapped.Length < 24 || wrapped.Length % 8 != 0) return null;
        int n = wrapped.Length / 8 - 1;
        var a = new byte[8]; Array.Copy(wrapped, 0, a, 0, 8);
        var r = new byte[n][];
        for (int i = 0; i < n; i++) { r[i] = new byte[8]; Array.Copy(wrapped, 8 * (i + 1), r[i], 0, 8); }
        using var aes = Aes.Create();
        aes.Key = kek; aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None;
        using var dec = aes.CreateDecryptor();
        var block = new byte[16];
        for (int j = 5; j >= 0; j--)
            for (int i = n; i >= 1; i--)
            {
                ulong t = (ulong)(n * j + i);
                var at = BinaryPrimitives.ReadUInt64BigEndian(a) ^ t;
                BinaryPrimitives.WriteUInt64BigEndian(block.AsSpan(0, 8), at);
                Array.Copy(r[i - 1], 0, block, 8, 8);
                var b = dec.TransformFinalBlock(block, 0, 16);
                Array.Copy(b, 0, a, 0, 8);
                Array.Copy(b, 8, r[i - 1], 0, 8);
            }
        if (!a.SequenceEqual(new byte[] { 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6 })) return null;
        var outp = new byte[n * 8];
        for (int i = 0; i < n; i++) Array.Copy(r[i], 0, outp, 8 * i, 8);
        return outp;
    }

    static byte[]? AesCbcZeroIv(byte[] key, byte[] data, PaddingMode padding)
    {
        try
        {
            using var aes = Aes.Create();
            aes.Key = key; aes.IV = new byte[16]; aes.Mode = CipherMode.CBC; aes.Padding = padding;
            var usable = padding == PaddingMode.None ? data.Length / 16 * 16 : data.Length;
            using var d = aes.CreateDecryptor();
            return d.TransformFinalBlock(data, 0, usable);
        }
        catch { return null; }
    }

    // MARK: Manifest

    SqliteConnection Db() => manifest ?? throw new BackupException(IsEncrypted ? "This backup is encrypted: unlock it first" : "Backup is closed");

    static BackupFile Row(SqliteDataReader r) =>
        new(r.GetString(0), r.GetString(1), r.IsDBNull(2) ? "" : r.GetString(2), 0, (r.IsDBNull(3) ? 1 : r.GetInt64(3)) == 2);

    public List<BackupFile> Files(string domain, string? prefix = null)
    {
        var list = new List<BackupFile>();
        using var cmd = Db().CreateCommand();
        cmd.CommandText = prefix == null
            ? "SELECT fileID, domain, relativePath, flags, file FROM Files WHERE domain = $d ORDER BY relativePath"
            : "SELECT fileID, domain, relativePath, flags, file FROM Files WHERE domain = $d AND relativePath >= $p AND relativePath < $q ORDER BY relativePath";
        cmd.Parameters.AddWithValue("$d", domain);
        if (prefix != null) { cmd.Parameters.AddWithValue("$p", prefix); cmd.Parameters.AddWithValue("$q", prefix + "\uFFFF"); }
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add(Row(r));
        return list;
    }

    public BackupFile? Find(string domain, string path)
    {
        using var cmd = Db().CreateCommand();
        cmd.CommandText = "SELECT fileID, domain, relativePath, flags, file FROM Files WHERE domain = $d AND relativePath = $p LIMIT 1";
        cmd.Parameters.AddWithValue("$d", domain); cmd.Parameters.AddWithValue("$p", path);
        using var r = cmd.ExecuteReader();
        return r.Read() ? Row(r) : null;
    }

    public List<BackupFile> VoiceMemoFiles()
    {
        var list = new List<BackupFile>();
        using var cmd = Db().CreateCommand();
        cmd.CommandText = "SELECT fileID, domain, relativePath, flags, file FROM Files WHERE domain = $d AND relativePath LIKE 'Recordings/%' AND LOWER(relativePath) LIKE '%.m4a' AND flags = 1 ORDER BY relativePath";
        cmd.Parameters.AddWithValue("$d", MediaDomain);
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add(Row(r));
        return list;
    }

    /// The MBFile record (an NSKeyedArchiver plist) for a fileID: Size, LastModified, EncryptionKey, ProtectionClass.
    (long size, DateTime? modified, byte[]? key) Record(string fileID)
    {
        using var cmd = Db().CreateCommand();
        cmd.CommandText = "SELECT file FROM Files WHERE fileID = $f LIMIT 1";
        cmd.Parameters.AddWithValue("$f", fileID);
        if (cmd.ExecuteScalar() is not byte[] blob) return (0, null, null);
        if (BinaryPlist.ParseAny(blob) is not Dictionary<string, object?> archive) return (0, null, null);
        if (archive.GetValueOrDefault("$objects") is not List<object?> objects || archive.GetValueOrDefault("$top") is not Dictionary<string, object?> top) return (0, null, null);
        // BinaryPlist renders a UID as its hex digits; the keys below only ever hold UIDs.
        object? Resolve(object? v) => v is string s && s.Length <= 8 && int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var i) && i < objects.Count ? objects[i] : v;
        if (Resolve(top.GetValueOrDefault("root")) is not Dictionary<string, object?> root) return (0, null, null);
        var size = Plist.Long(root.GetValueOrDefault("Size")) ?? 0;
        var lm = Plist.Long(root.GetValueOrDefault("LastModified")) ?? 0;
        DateTime? modified = lm > 0 ? DateTimeOffset.FromUnixTimeSeconds(lm).LocalDateTime : null;
        var keyObj = Resolve(root.GetValueOrDefault("EncryptionKey"));
        byte[]? key = keyObj as byte[] ?? (keyObj is Dictionary<string, object?> kd ? Resolve(kd.GetValueOrDefault("NS.data")) as byte[] : null);
        return (size, modified, key);
    }

    string BlobPath(string fileID)
    {
        var p = Path.Combine(folder, fileID[..2], fileID);
        return File.Exists(p) ? p : Path.Combine(folder, fileID);
    }

    public byte[] Read(BackupFile f)
    {
        if (f.IsDirectory) throw new BackupException($"{f.RelativePath} is a folder");
        var p = BlobPath(f.FileID);
        if (!File.Exists(p)) throw new BackupException($"{f.RelativePath} is missing from the backup folder");
        var raw = File.ReadAllBytes(p);
        if (!IsEncrypted) return raw;
        var (size, _, key) = Record(f.FileID);
        if (key == null || key.Length < 44) return raw;
        var cls = BinaryPrimitives.ReadUInt32LittleEndian(key.AsSpan(0, 4));
        if (!classKeys.TryGetValue(cls, out var ck)) throw new BackupException($"No key for protection class {cls} ({f.RelativePath})");
        var fileKey = AesUnwrap(ck, key[4..44]) ?? throw new BackupException($"Could not unwrap the key of {f.RelativePath}");
        var plain = AesCbcZeroIv(fileKey, raw, PaddingMode.None) ?? throw new BackupException($"Could not decrypt {f.RelativePath}");
        if (size > 0 && plain.Length > size) plain = plain[..(int)size];
        return plain;
    }

    public void Extract(BackupFile f, string to, DateTime? date = null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(to)!);
        File.WriteAllBytes(to, Read(f));
        var (_, modified, _) = Record(f.FileID);
        var when = date ?? modified;
        if (when != null) try { File.SetLastWriteTime(to, when.Value); } catch { }
    }

    /// A database from the backup, copied (with its WAL) into scratch and opened read-only. Null when absent.
    SqliteConnection? Database(string domain, string path)
    {
        var key = domain + "|" + path;
        if (dbCache.TryGetValue(key, out var cached)) return cached;
        SqliteConnection? conn = null;
        var f = Find(domain, path);
        if (f != null && !f.IsDirectory)
        {
            var dir = Path.Combine(scratch, Guid.NewGuid().ToString("N"));
            var local = Path.Combine(dir, Path.GetFileName(path));
            try
            {
                Extract(f, local);
                foreach (var suffix in new[] { "-wal", "-shm" })
                    if (Find(domain, path + suffix) is BackupFile side && !side.IsDirectory) Extract(side, local + suffix);
                conn = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = local, Mode = SqliteOpenMode.ReadWrite }.ToString());
                conn.Open();
            }
            catch (BackupException) { conn = null; }
        }
        dbCache[key] = conn;
        return conn;
    }

    static long Scalar(SqliteConnection c, string sql)
    {
        try { using var cmd = c.CreateCommand(); cmd.CommandText = sql; return Convert.ToInt64(cmd.ExecuteScalar() ?? 0); } catch { return 0; }
    }
    static bool HasTable(SqliteConnection c, string t)
    {
        using var cmd = c.CreateCommand(); cmd.CommandText = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = $n"; cmd.Parameters.AddWithValue("$n", t);
        return cmd.ExecuteScalar() != null;
    }
    static bool HasColumn(SqliteConnection c, string t, string col)
    {
        using var cmd = c.CreateCommand(); cmd.CommandText = $"PRAGMA table_info(\"{t}\")";
        using var r = cmd.ExecuteReader();
        while (r.Read()) if (string.Equals(r.GetString(1), col, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
    static long Count(SqliteConnection c, string t) => HasTable(c, t) ? Scalar(c, $"SELECT COUNT(*) FROM \"{t}\"") : 0;
    static string Col(SqliteConnection c, string t, string col) => HasColumn(c, t, col) ? col : $"NULL AS {col}";

    // MARK: Summary

    public BackupSummary Summary()
    {
        var s = new BackupSummary();
        if (Database(HomeDomain, "Library/SMS/sms.db") is SqliteConnection sms) { s.Messages = (int)Count(sms, "message"); s.Conversations = (int)Count(sms, "chat"); }
        if (Database(HomeDomain, "Library/AddressBook/AddressBook.sqlitedb") is SqliteConnection ab) s.Contacts = (int)Count(ab, "ABPerson");
        if (Database(HomeDomain, "Library/CallHistoryDB/CallHistory.storedata") is SqliteConnection ch) s.Calls = (int)Count(ch, "ZCALLRECORD");
        if (Database(NotesDomain, "NoteStore.sqlite") is SqliteConnection ns && HasTable(ns, "ZICCLOUDSYNCINGOBJECT"))
        {
            var sql = "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTEDATA IS NOT NULL";
            if (HasColumn(ns, "ZICCLOUDSYNCINGOBJECT", "ZMARKEDFORDELETION")) sql += " AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0)";
            s.Notes = (int)Scalar(ns, sql);
        }
        else if (Database(HomeDomain, "Library/Notes/notes.sqlite") is SqliteConnection ln) s.Notes = (int)Count(ln, "ZNOTE");
        s.VoiceMemos = VoiceMemoFiles().Count;
        if (Database(HomeDomain, "Library/Safari/History.db") is SqliteConnection sh) s.SafariHistory = (int)Count(sh, "history_visits");
        if (Database(WhatsappDomain, "ChatStorage.sqlite") is SqliteConnection wa) { s.WhatsappChats = (int)Count(wa, "ZWACHATSESSION"); s.WhatsappMessages = (int)Count(wa, "ZWAMESSAGE"); }
        return s;
    }

    // MARK: Export

    public Dictionary<BackupExport, int> Export(IEnumerable<BackupExport> kinds, string folder, Action<string> progress)
    {
        Directory.CreateDirectory(folder);
        var counts = new Dictionary<BackupExport, int>();
        foreach (var k in kinds)
        {
            progress(k.Title());
            counts[k] = k switch
            {
                BackupExport.Messages => ExportMessages(folder, progress),
                BackupExport.Contacts => ExportContacts(folder, progress),
                BackupExport.Calls => ExportCalls(folder),
                BackupExport.Notes => ExportNotes(folder, progress),
                BackupExport.VoiceMemos => ExportVoiceMemos(folder, progress),
                BackupExport.Safari => ExportSafari(folder),
                _ => ExportWhatsapp(folder, progress),
            };
        }
        return counts;
    }

    static string Sanitize(string name)
    {
        var s = name.Replace('/', '-').Replace(':', '-');
        s = Regex.Replace(s, "[\\\\*?\"<>|]", "-");
        s = new string(s.Where(c => !char.IsControl(c)).ToArray()).Trim().TrimStart('.');
        if (s.Length > 80) s = s[..80].Trim();
        if (s.Length == 0) s = "Untitled";
        var upper = s.ToUpperInvariant();
        if (upper is "CON" or "PRN" or "AUX" or "NUL" || Regex.IsMatch(upper, "^(COM|LPT)[1-9]$")) s += "_";
        return s;
    }
    static string Fmt(DateTime? d) => d == null ? "" : d.Value.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
    static DateTime? AppleDate(object? v)
    {
        double? x = v switch { long l => l, double d => d, int i => i, decimal m => (double)m, string s when double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var p) => p, _ => null };
        if (x == null || x == 0) return null;
        var secs = x.Value > 1e12 ? x.Value / 1e9 : x.Value;
        return new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(secs).ToLocalTime();
    }
    static string Csv(params string[] fields) => string.Join(",", fields.Select(f => f.IndexOfAny(new[] { ',', '"', '\n', '\r' }) >= 0 ? "\"" + f.Replace("\"", "\"\"") + "\"" : f)) + "\n";
    static string Html(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;").Replace("\n", "<br>");
    static string UrlPath(string s) => string.Join("/", s.Split('/').Select(Uri.EscapeDataString));

    sealed class Namer
    {
        readonly HashSet<string> used = new(StringComparer.OrdinalIgnoreCase);
        public string Unique(string b, string ext)
        {
            var name = b + ext; int n = 2;
            while (!used.Add(name)) name = $"{b} ({n++}){ext}";
            return name;
        }
    }

    sealed record ChatLine(DateTime? Date, string Sender, string Text, List<(string name, string href)> Attachments);

    static void WriteChat(string title, List<ChatLine> lines, string basePath)
    {
        var txt = new StringBuilder();
        txt.Append(title).Append('\n').Append(new string('=', Math.Min(title.Length, 60))).Append("\n\n");
        foreach (var l in lines)
        {
            txt.Append('[').Append(Fmt(l.Date)).Append("] ").Append(l.Sender).Append(": ").Append(l.Text);
            foreach (var (_, href) in l.Attachments) txt.Append("\n    [attachment: ").Append(href).Append(']');
            txt.Append('\n');
        }
        File.WriteAllText(basePath + ".txt", txt.ToString(), new UTF8Encoding(false));
        var h = new StringBuilder();
        h.Append("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>").Append(Html(title)).Append("</title>\n<style>\n")
         .Append("body{font-family:-apple-system,BlinkMacSystemFont,\"Helvetica Neue\",sans-serif;font-size:14px;line-height:1.4;margin:0;padding:24px;background:#f5f5f7;color:#1d1d1f}\n")
         .Append("h1{font-size:20px;margin:0 0 16px}\n")
         .Append(".m{display:grid;grid-template-columns:130px 140px 1fr;gap:12px;padding:8px 12px;margin:4px 0;border-radius:10px;background:#fff}\n")
         .Append(".m.me{background:#dcefff}\n")
         .Append(".t{color:#6e6e73;font-variant-numeric:tabular-nums;white-space:nowrap}\n")
         .Append(".s{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\n")
         .Append(".x{overflow-wrap:anywhere}\n")
         .Append(".a{display:block;margin-top:4px;font-size:13px}\n")
         .Append("@media (max-width:640px){.m{grid-template-columns:1fr}}\n")
         .Append("</style></head><body>\n<h1>").Append(Html(title)).Append("</h1>\n");
        foreach (var l in lines)
        {
            h.Append("<div class=\"m").Append(l.Sender == "Me" ? " me" : "").Append("\"><div class=\"t\">").Append(Fmt(l.Date)).Append("</div><div class=\"s\">")
             .Append(Html(l.Sender)).Append("</div><div class=\"x\">").Append(Html(l.Text));
            foreach (var (name, href) in l.Attachments) h.Append("<a class=\"a\" href=\"").Append(UrlPath(href)).Append("\">").Append(Html(name)).Append("</a>");
            h.Append("</div></div>\n");
        }
        h.Append("</body></html>\n");
        File.WriteAllText(basePath + ".html", h.ToString(), new UTF8Encoding(false));
    }

    static string TextFromAttributedBody(byte[] data)
    {
        try
        {
            var marker = Encoding.ASCII.GetBytes("NSString");
            int at = -1;
            for (int i = 0; i + marker.Length <= data.Length; i++) { if (data.AsSpan(i, marker.Length).SequenceEqual(marker)) { at = i; break; } }
            if (at < 0) return "";
            int p = at + marker.Length;
            while (p < data.Length && data[p] != 0x2B) p++;
            p++;
            if (p >= data.Length) return "";
            int len = data[p++];
            if (len == 0x81) { len = data[p] | (data[p + 1] << 8); p += 2; }
            else if (len == 0x82) { len = data[p] | (data[p + 1] << 8) | (data[p + 2] << 16) | (data[p + 3] << 24); p += 4; }
            if (p + len > data.Length) return "";
            return Encoding.UTF8.GetString(data, p, len);
        }
        catch { return ""; }
    }

    int ExportMessages(string folder, Action<string> progress)
    {
        var db = Database(HomeDomain, "Library/SMS/sms.db");
        if (db == null) return 0;
        var dir = Path.Combine(folder, "Messages"); Directory.CreateDirectory(dir);
        var attDir = Path.Combine(dir, "Attachments");
        var handles = new Dictionary<long, string>();
        using (var c = db.CreateCommand()) { c.CommandText = "SELECT ROWID, id FROM handle"; using var r = c.ExecuteReader(); while (r.Read()) handles[r.GetInt64(0)] = r.IsDBNull(1) ? "" : r.GetString(1); }
        var hasChatHandles = HasTable(db, "chat_handle_join");
        var hasAttachments = HasTable(db, "attachment") && HasTable(db, "message_attachment_join");
        var hasBody = HasColumn(db, "message", "attributedBody");
        var hasService = HasColumn(db, "message", "service");
        var chats = new List<(long id, string ident, string display)>();
        using (var c = db.CreateCommand()) { c.CommandText = "SELECT ROWID, chat_identifier, display_name FROM chat ORDER BY ROWID"; using var r = c.ExecuteReader(); while (r.Read()) chats.Add((r.GetInt64(0), r.IsDBNull(1) ? "" : r.GetString(1), r.IsDBNull(2) ? "" : r.GetString(2))); }
        var namer = new Namer(); int total = 0; var copied = new HashSet<long>();
        for (int i = 0; i < chats.Count; i++)
        {
            var (id, ident, display) = chats[i];
            var name = display;
            if (name == "" && hasChatHandles)
            {
                using var c = db.CreateCommand(); c.CommandText = $"SELECT h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = {id} ORDER BY h.id";
                using var r = c.ExecuteReader(); var parts = new List<string>(); while (r.Read()) if (!r.IsDBNull(0)) parts.Add(r.GetString(0));
                name = string.Join(", ", parts);
            }
            if (name == "") name = ident != "" ? ident : $"Chat {id}";
            progress($"Messages: {name} ({i + 1} of {chats.Count})");
            var lines = new List<ChatLine>();
            using (var c = db.CreateCommand())
            {
                c.CommandText = $"SELECT m.ROWID, m.text, m.handle_id, m.date, m.is_from_me{(hasBody ? ", m.attributedBody" : "")}{(hasService ? ", m.service" : "")} FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = {id} ORDER BY m.date";
                using var r = c.ExecuteReader();
                while (r.Read())
                {
                    var mid = r.GetInt64(0);
                    var text = r.IsDBNull(1) ? "" : r.GetString(1);
                    if (text == "" && hasBody && !r.IsDBNull(5) && r.GetValue(5) is byte[] body) text = TextFromAttributedBody(body);
                    var fromMe = !r.IsDBNull(4) && r.GetInt64(4) != 0;
                    var sender = fromMe ? "Me" : (!r.IsDBNull(2) && handles.TryGetValue(r.GetInt64(2), out var hn) ? hn : "Unknown");
                    var date = r.IsDBNull(3) ? null : AppleDate(r.GetValue(3));
                    var atts = new List<(string, string)>();
                    if (hasAttachments)
                    {
                        using var ac = db.CreateCommand();
                        ac.CommandText = $"SELECT a.ROWID, a.filename, a.transfer_name FROM attachment a JOIN message_attachment_join j ON j.attachment_id = a.ROWID WHERE j.message_id = {mid}";
                        using var ar = ac.ExecuteReader();
                        while (ar.Read())
                        {
                            var aid = ar.GetInt64(0);
                            var filename = ar.IsDBNull(1) ? "" : ar.GetString(1);
                            var displayName = ar.IsDBNull(2) ? "" : ar.GetString(2);
                            if (displayName == "") displayName = filename.Split('/').LastOrDefault() ?? "";
                            var rel = filename;
                            if (rel.StartsWith("~/")) rel = rel[2..];
                            else if (rel.StartsWith("/") && rel.Contains("/Library/")) rel = rel[(rel.IndexOf("Library/", StringComparison.Ordinal))..];
                            var href = "";
                            var f = Find(MediaDomain, rel) ?? Find(HomeDomain, rel);
                            if (f != null)
                            {
                                var target = $"{aid}_{Sanitize(rel.Split('/').Last())}";
                                if (copied.Add(aid)) { try { Extract(f, Path.Combine(attDir, target)); } catch { } }
                                href = "Attachments/" + target;
                            }
                            atts.Add((displayName == "" ? "attachment" : displayName, href == "" ? $"(missing: {displayName})" : href));
                        }
                    }
                    lines.Add(new ChatLine(date, sender, text, atts));
                }
            }
            if (lines.Count == 0) continue;
            WriteChat(name, lines, Path.Combine(dir, namer.Unique(Sanitize(name), "")));
            total += lines.Count;
        }
        return total;
    }

    static string VEscape(string s) => s.Replace("\\", "\\\\").Replace(";", "\\;").Replace(",", "\\,").Replace("\r\n", "\\n").Replace("\n", "\\n");
    static string VType(string label)
    {
        if (label == "") return "";
        var map = new Dictionary<string, string> { ["Mobile"] = "CELL", ["iPhone"] = "CELL", ["Home"] = "HOME", ["Work"] = "WORK", ["Main"] = "PREF", ["HomeFAX"] = "FAX,HOME", ["WorkFAX"] = "FAX,WORK", ["Pager"] = "PAGER", ["Other"] = "OTHER", ["HomePage"] = "HOME" };
        if (map.TryGetValue(label, out var t)) return ";TYPE=" + t;
        var clean = new string(label.Where(c => char.IsLetterOrDigit(c) || c == '-').ToArray()).ToUpperInvariant();
        return clean == "" ? "" : ";TYPE=" + clean;
    }
    static string Fold(string line)
    {
        var sb = new StringBuilder(); int count = 0;
        foreach (var ch in line)
        {
            var n = Encoding.UTF8.GetByteCount(ch.ToString());
            if (count + n > 75) { sb.Append("\r\n "); count = 1; }
            sb.Append(ch); count += n;
        }
        return sb.ToString();
    }

    int ExportContacts(string folder, Action<string> progress)
    {
        var db = Database(HomeDomain, "Library/AddressBook/AddressBook.sqlitedb");
        if (db == null) return 0;
        var labels = new Dictionary<long, string>();
        using (var c = db.CreateCommand()) { c.CommandText = "SELECT ROWID, value FROM ABMultiValueLabel"; using var r = c.ExecuteReader(); while (r.Read()) { var v = r.IsDBNull(1) ? "" : r.GetString(1); if (v.StartsWith("_$!<") && v.EndsWith(">!$_")) v = v[4..^4]; labels[r.GetInt64(0)] = v; } }
        var keys = new Dictionary<long, string>();
        if (HasTable(db, "ABMultiValueEntryKey")) using (var c = db.CreateCommand()) { c.CommandText = "SELECT ROWID, value FROM ABMultiValueEntryKey"; using var r = c.ExecuteReader(); while (r.Read()) keys[r.GetInt64(0)] = r.IsDBNull(1) ? "" : r.GetString(1); }
        var multi = new Dictionary<long, Dictionary<long, List<(string label, string value, long uid)>>>();
        using (var c = db.CreateCommand())
        {
            c.CommandText = "SELECT UID, record_id, property, label, value FROM ABMultiValue ORDER BY UID"; using var r = c.ExecuteReader();
            while (r.Read())
            {
                var rec = r.GetInt64(1); var prop = r.GetInt64(2);
                var label = r.IsDBNull(3) ? "" : labels.GetValueOrDefault(r.GetInt64(3), "");
                var value = r.IsDBNull(4) ? "" : r.GetValue(4) is byte[] b ? Encoding.UTF8.GetString(b) : r.GetValue(4).ToString() ?? "";
                if (!multi.TryGetValue(rec, out var props)) multi[rec] = props = new();
                if (!props.TryGetValue(prop, out var list)) props[prop] = list = new();
                list.Add((label, value, r.GetInt64(0)));
            }
        }
        var entries = new Dictionary<long, Dictionary<string, string>>();
        if (HasTable(db, "ABMultiValueEntry")) using (var c = db.CreateCommand())
        {
            c.CommandText = "SELECT parent_id, key, value FROM ABMultiValueEntry"; using var r = c.ExecuteReader();
            while (r.Read())
            {
                var pid = r.GetInt64(0); var keyName = r.IsDBNull(1) ? "" : keys.GetValueOrDefault(r.GetInt64(1), "");
                if (!entries.TryGetValue(pid, out var d)) entries[pid] = d = new();
                d[keyName] = r.IsDBNull(2) ? "" : r.GetValue(2).ToString() ?? "";
            }
        }
        var photos = new Dictionary<long, byte[]>();
        if (Database(HomeDomain, "Library/AddressBook/AddressBookImages.sqlitedb") is SqliteConnection img)
            foreach (var table in new[] { "ABFullSizeImage", "ABThumbnailImage" })
            {
                if (!HasTable(img, table)) continue;
                using var c = img.CreateCommand(); c.CommandText = $"SELECT record_id, data FROM {table} WHERE data IS NOT NULL"; using var r = c.ExecuteReader();
                while (r.Read()) { var rec = r.GetInt64(0); if (!photos.ContainsKey(rec) && r.GetValue(1) is byte[] b && b.Length > 0) photos[rec] = b; }
            }
        var optional = new[] { "Middle", "Organization", "Note", "Birthday", "JobTitle", "Department", "Nickname", "Prefix", "Suffix" };
        var cols = "ROWID, First, Last, " + string.Join(", ", optional.Select(o => Col(db, "ABPerson", o)));
        var vcf = new StringBuilder(); var csv = new StringBuilder(Csv("Name", "Phones", "Emails", "Organization"));
        int n = 0;
        using (var c = db.CreateCommand())
        {
            c.CommandText = $"SELECT {cols} FROM ABPerson ORDER BY ROWID"; using var r = c.ExecuteReader();
            var rows = new List<object?[]>();
            while (r.Read()) { var row = new object?[r.FieldCount]; r.GetValues(row!); rows.Add(row); }
            string S(object? v) => v is null or DBNull ? "" : v.ToString() ?? "";
            for (int i = 0; i < rows.Count; i++)
            {
                if (i % 50 == 0) progress($"Contacts: {i + 1} of {rows.Count}");
                var row = rows[i];
                var rec = Convert.ToInt64(row[0]);
                string first = S(row[1]), last = S(row[2]), middle = S(row[3]), org = S(row[4]), note = S(row[5]);
                var birthday = AppleDate(row[6] is DBNull ? null : row[6]);
                string title = S(row[7]), dept = S(row[8]), nick = S(row[9]), prefix = S(row[10]), suffix = S(row[11]);
                var full = string.Join(" ", new[] { prefix, first, middle, last, suffix }.Where(p => p != ""));
                var display = full != "" ? full : org != "" ? org : "Unnamed";
                var props = multi.GetValueOrDefault(rec) ?? new();
                var v = new StringBuilder();
                v.Append("BEGIN:VCARD\r\nVERSION:3.0\r\n");
                v.Append("FN:").Append(VEscape(display)).Append("\r\n");
                v.Append("N:").Append(VEscape(last)).Append(';').Append(VEscape(first)).Append(';').Append(VEscape(middle)).Append(';').Append(VEscape(prefix)).Append(';').Append(VEscape(suffix)).Append("\r\n");
                if (org != "") v.Append("ORG:").Append(VEscape(org)).Append(dept != "" ? ";" + VEscape(dept) : "").Append("\r\n");
                if (title != "") v.Append("TITLE:").Append(VEscape(title)).Append("\r\n");
                if (nick != "") v.Append("NICKNAME:").Append(VEscape(nick)).Append("\r\n");
                if (birthday != null) v.Append("BDAY:").Append(birthday.Value.ToUniversalTime().ToString("yyyy-MM-dd")).Append("\r\n");
                var phones = new List<string>(); var emails = new List<string>();
                foreach (var (label, value, _) in props.GetValueOrDefault(3) ?? new()) if (value != "") { v.Append("TEL").Append(VType(label)).Append(':').Append(VEscape(value)).Append("\r\n"); phones.Add(value); }
                foreach (var (label, value, _) in props.GetValueOrDefault(4) ?? new()) if (value != "") { v.Append("EMAIL").Append(VType(label)).Append(':').Append(VEscape(value)).Append("\r\n"); emails.Add(value); }
                foreach (var (label, _, uid) in props.GetValueOrDefault(5) ?? new())
                {
                    var e = entries.GetValueOrDefault(uid) ?? new();
                    var parts = new[] { e.GetValueOrDefault("Street", ""), e.GetValueOrDefault("City", ""), e.GetValueOrDefault("State", ""), e.GetValueOrDefault("ZIP", ""), e.GetValueOrDefault("Country", "") };
                    if (parts.All(p => p == "")) continue;
                    v.Append("ADR").Append(VType(label)).Append(":;;").Append(string.Join(";", parts.Select(VEscape))).Append("\r\n");
                }
                foreach (var (label, value, _) in props.GetValueOrDefault(22) ?? new()) if (value != "") v.Append("URL").Append(VType(label)).Append(':').Append(VEscape(value)).Append("\r\n");
                if (note != "") v.Append("NOTE:").Append(VEscape(note)).Append("\r\n");
                if (photos.TryGetValue(rec, out var photo))
                {
                    var png = photo.Length > 4 && photo[0] == 0x89 && photo[1] == 0x50 && photo[2] == 0x4E && photo[3] == 0x47;
                    v.Append(Fold($"PHOTO;ENCODING=b;TYPE={(png ? "PNG" : "JPEG")}:{Convert.ToBase64String(photo)}")).Append("\r\n");
                }
                v.Append("END:VCARD\r\n");
                vcf.Append(v);
                csv.Append(Csv(display, string.Join("; ", phones), string.Join("; ", emails), org));
                n++;
            }
        }
        File.WriteAllText(Path.Combine(folder, "Contacts.vcf"), vcf.ToString(), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(folder, "Contacts.csv"), csv.ToString(), new UTF8Encoding(false));
        return n;
    }

    int ExportCalls(string folder)
    {
        var db = Database(HomeDomain, "Library/CallHistoryDB/CallHistory.storedata");
        if (db == null || !HasTable(db, "ZCALLRECORD")) return 0;
        var cols = new[] { "ZADDRESS", "ZDATE", "ZDURATION", "ZORIGINATED", "ZANSWERED", "ZCALLTYPE", "ZNAME" };
        var sb = new StringBuilder(Csv("Date", "Number/Address", "Name", "Direction", "Type", "Duration"));
        int n = 0;
        using var c = db.CreateCommand();
        c.CommandText = $"SELECT {string.Join(", ", cols.Select(x => Col(db, "ZCALLRECORD", x)))} FROM ZCALLRECORD ORDER BY ZDATE DESC";
        using var r = c.ExecuteReader();
        while (r.Read())
        {
            var address = r.IsDBNull(0) ? "" : r.GetValue(0) is byte[] b ? Encoding.UTF8.GetString(b) : r.GetValue(0).ToString() ?? "";
            var date = r.IsDBNull(1) ? null : AppleDate(r.GetValue(1));
            var dur = r.IsDBNull(2) ? 0 : (int)Math.Round(Convert.ToDouble(r.GetValue(2)));
            var originated = !r.IsDBNull(3) && Convert.ToInt64(r.GetValue(3)) != 0;
            var answered = r.IsDBNull(4) || Convert.ToInt64(r.GetValue(4)) != 0;
            var type = r.IsDBNull(5) ? 1 : Convert.ToInt64(r.GetValue(5));
            var name = r.IsDBNull(6) ? "" : r.GetValue(6).ToString() ?? "";
            var direction = originated ? "Outgoing" : answered ? "Incoming" : "Missed";
            var typeText = type switch { 1 => "Phone", 8 => "FaceTime video", 16 => "FaceTime audio", _ => $"Other ({type})" };
            sb.Append(Csv(Fmt(date), address, name, direction, typeText, $"{dur / 60}:{dur % 60:00}"));
            n++;
        }
        File.WriteAllText(Path.Combine(folder, "Call history.csv"), sb.ToString(), new UTF8Encoding(false));
        return n;
    }

    static byte[]? Gunzip(byte[] data)
    {
        try
        {
            if (data.Length > 3 && data[0] == 0x1F && data[1] == 0x8B && data[2] == 0x08)
            { using var gz = new GZipStream(new MemoryStream(data), CompressionMode.Decompress); using var o = new MemoryStream(); gz.CopyTo(o); return o.ToArray(); }
            using var df = new DeflateStream(new MemoryStream(data), CompressionMode.Decompress); using var o2 = new MemoryStream(); df.CopyTo(o2); return o2.ToArray();
        }
        catch { return null; }
    }

    /// Protobuf: top-level field 2, then field 3, then field 2, each length-delimited; that holds the note text.
    static string? NoteText(byte[] pb)
    {
        byte[]? Field(byte[] buf, int want)
        {
            int p = 0;
            while (p < buf.Length)
            {
                ulong key = 0; int shift = 0;
                while (p < buf.Length) { var b = buf[p++]; key |= (ulong)(b & 0x7F) << shift; if ((b & 0x80) == 0) break; shift += 7; }
                int field = (int)(key >> 3), wire = (int)(key & 7);
                if (wire == 2)
                {
                    ulong len = 0; shift = 0;
                    while (p < buf.Length) { var b = buf[p++]; len |= (ulong)(b & 0x7F) << shift; if ((b & 0x80) == 0) break; shift += 7; }
                    if (p + (int)len > buf.Length) return null;
                    if (field == want) return buf[p..(p + (int)len)];
                    p += (int)len;
                }
                else if (wire == 0) { while (p < buf.Length && (buf[p++] & 0x80) != 0) { } }
                else if (wire == 1) p += 8;
                else if (wire == 5) p += 4;
                else return null;
            }
            return null;
        }
        var a = Field(pb, 2); if (a == null) return null;
        var b = Field(a, 3); if (b == null) return null;
        var c = Field(b, 2); if (c == null) return null;
        return Encoding.UTF8.GetString(c);
    }

    static string StripHtml(string s)
    {
        s = Regex.Replace(s, "<br[^>]*>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, "</(p|div|li|h[1-6])>", "\n", RegexOptions.IgnoreCase);
        s = Regex.Replace(s, "<[^>]+>", "");
        return s.Replace("&nbsp;", " ").Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"").Replace("&#39;", "'").Replace("&amp;", "&").Trim();
    }

    int ExportNotes(string folder, Action<string> progress)
    {
        var dir = Path.Combine(folder, "Notes");
        var notes = new List<(string title, DateTime? modified, string text)>();
        if (Database(NotesDomain, "NoteStore.sqlite") is SqliteConnection ns && HasTable(ns, "ZICCLOUDSYNCINGOBJECT"))
        {
            var del = HasColumn(ns, "ZICCLOUDSYNCINGOBJECT", "ZMARKEDFORDELETION") ? " AND (o.ZMARKEDFORDELETION IS NULL OR o.ZMARKEDFORDELETION = 0)" : "";
            string C(string col) => HasColumn(ns, "ZICCLOUDSYNCINGOBJECT", col) ? "o." + col : "NULL";
            using var c = ns.CreateCommand();
            c.CommandText = $"SELECT {C("ZTITLE1")} AS title, {C("ZSNIPPET")} AS snippet, {C("ZMODIFICATIONDATE1")} AS modified, d.ZDATA AS data FROM ZICCLOUDSYNCINGOBJECT o JOIN ZICNOTEDATA d ON d.Z_PK = o.ZNOTEDATA WHERE o.ZNOTEDATA IS NOT NULL{del} ORDER BY o.Z_PK";
            using var r = c.ExecuteReader();
            while (r.Read())
            {
                var title = r.IsDBNull(0) ? "" : r.GetString(0);
                var snippet = r.IsDBNull(1) ? "" : r.GetString(1);
                var modified = r.IsDBNull(2) ? null : AppleDate(r.GetValue(2));
                string? text = null;
                if (!r.IsDBNull(3) && r.GetValue(3) is byte[] data && Gunzip(data) is byte[] pb) text = NoteText(pb);
                text ??= snippet;
                if (title == "") title = text.Split('\n').FirstOrDefault(l => l.Trim() != "")?.Trim() ?? "";
                if (title == "") title = "Untitled";
                notes.Add((title, modified, text));
            }
        }
        else if (Database(HomeDomain, "Library/Notes/notes.sqlite") is SqliteConnection ln && HasTable(ln, "ZNOTE"))
        {
            using var c = ln.CreateCommand();
            c.CommandText = "SELECT n.ZTITLE AS title, n.ZMODIFICATIONDATE AS modified, b.ZCONTENT AS body FROM ZNOTE n LEFT JOIN ZNOTEBODY b ON b.Z_PK = n.ZBODY ORDER BY n.Z_PK";
            using var r = c.ExecuteReader();
            while (r.Read())
            {
                var title = r.IsDBNull(0) ? "" : r.GetString(0);
                var modified = r.IsDBNull(1) ? null : AppleDate(r.GetValue(1));
                var text = StripHtml(r.IsDBNull(2) ? "" : r.GetString(2));
                if (title == "") title = text.Split('\n').FirstOrDefault(l => l.Trim() != "")?.Trim() ?? "Untitled";
                notes.Add((title, modified, text));
            }
        }
        if (notes.Count == 0) return 0;
        Directory.CreateDirectory(dir);
        var namer = new Namer(); var index = new StringBuilder(Csv("Title", "Modified", "File"));
        for (int i = 0; i < notes.Count; i++)
        {
            if (i % 20 == 0) progress($"Notes: {i + 1} of {notes.Count}");
            var (title, modified, text) = notes[i];
            var file = namer.Unique(Sanitize(title), ".txt");
            var path = Path.Combine(dir, file);
            File.WriteAllText(path, text, new UTF8Encoding(false));
            if (modified != null) try { File.SetLastWriteTime(path, modified.Value); } catch { }
            index.Append(Csv(title, Fmt(modified), file));
        }
        File.WriteAllText(Path.Combine(dir, "index.csv"), index.ToString(), new UTF8Encoding(false));
        return notes.Count;
    }

    int ExportVoiceMemos(string folder, Action<string> progress)
    {
        var files = VoiceMemoFiles();
        if (files.Count == 0) return 0;
        var dir = Path.Combine(folder, "Voice Memos"); Directory.CreateDirectory(dir);
        var labels = new Dictionary<string, (string title, DateTime? date)>();
        if (Database(MediaDomain, "Recordings/CloudRecordings.db") is SqliteConnection cr && HasTable(cr, "ZCLOUDRECORDING"))
        {
            using var c = cr.CreateCommand();
            c.CommandText = $"SELECT {Col(cr, "ZCLOUDRECORDING", "ZCUSTOMLABEL")}, {Col(cr, "ZCLOUDRECORDING", "ZENCRYPTEDTITLE")}, {Col(cr, "ZCLOUDRECORDING", "ZPATH")}, {Col(cr, "ZCLOUDRECORDING", "ZDATE")} FROM ZCLOUDRECORDING";
            using var r = c.ExecuteReader();
            while (r.Read())
            {
                var path = r.IsDBNull(2) ? "" : r.GetString(2);
                var key = path.Split('/').Last();
                var title = r.IsDBNull(0) ? "" : r.GetString(0);
                if (title == "" && !r.IsDBNull(1)) title = r.GetString(1);
                labels[key] = (title, r.IsDBNull(3) ? null : AppleDate(r.GetValue(3)));
            }
        }
        var namer = new Namer(); int n = 0;
        for (int i = 0; i < files.Count; i++)
        {
            var f = files[i];
            var fileName = f.RelativePath.Split('/').Last();
            var label = labels.GetValueOrDefault(fileName);
            var baseName = label.title != "" && label.title != null ? label.title : Path.GetFileNameWithoutExtension(fileName);
            progress($"Voice memos: {baseName} ({i + 1} of {files.Count})");
            try { Extract(f, Path.Combine(dir, namer.Unique(Sanitize(baseName), ".m4a")), label.date); n++; } catch { }
        }
        return n;
    }

    int ExportSafari(string folder)
    {
        int n = 0;
        if (Database(HomeDomain, "Library/Safari/History.db") is SqliteConnection h && HasTable(h, "history_visits"))
        {
            var sb = new StringBuilder(Csv("Date", "Title", "URL"));
            using var c = h.CreateCommand();
            c.CommandText = $"SELECT v.visit_time AS t, {(HasColumn(h, "history_visits", "title") ? "v.title" : "NULL")} AS title, i.url AS url FROM history_visits v JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC";
            using var r = c.ExecuteReader();
            while (r.Read())
            {
                sb.Append(Csv(Fmt(r.IsDBNull(0) ? null : AppleDate(r.GetValue(0))), r.IsDBNull(1) ? "" : r.GetString(1), r.IsDBNull(2) ? "" : r.GetString(2)));
                n++;
            }
            File.WriteAllText(Path.Combine(folder, "Safari history.csv"), sb.ToString(), new UTF8Encoding(false));
        }
        if (Database(HomeDomain, "Library/Safari/Bookmarks.db") is SqliteConnection b && HasTable(b, "bookmarks"))
        {
            var rows = new List<(long id, string title, string url, long parent, long type)>();
            using (var c = b.CreateCommand())
            {
                c.CommandText = $"SELECT id, title, url, parent, type FROM bookmarks ORDER BY {(HasColumn(b, "bookmarks", "order_index") ? "order_index" : "id")}";
                using var r = c.ExecuteReader();
                while (r.Read()) rows.Add((r.GetInt64(0), r.IsDBNull(1) ? "" : r.GetString(1), r.IsDBNull(2) ? "" : r.GetString(2), r.IsDBNull(3) ? 0 : r.GetInt64(3), r.IsDBNull(4) ? 0 : r.GetInt64(4)));
            }
            var ids = rows.Select(x => x.id).ToHashSet();
            var sb = new StringBuilder("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<!-- This is an automatically generated file. -->\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n");
            var seen = new HashSet<long>();
            void Walk(long parent, int depth)
            {
                var pad = new string(' ', depth * 4);
                foreach (var row in rows.Where(x => x.parent == parent))
                {
                    if (!seen.Add(row.id)) continue;
                    if (row.type == 1)
                    {
                        sb.Append(pad).Append("<DT><H3>").Append(Html(row.title == "" ? "Folder" : row.title)).Append("</H3>\n").Append(pad).Append("<DL><p>\n");
                        Walk(row.id, depth + 1);
                        sb.Append(pad).Append("</DL><p>\n");
                    }
                    else if (row.url != "") sb.Append(pad).Append("<DT><A HREF=\"").Append(Html(row.url)).Append("\">").Append(Html(row.title == "" ? row.url : row.title)).Append("</A>\n");
                }
            }
            foreach (var root in rows.Select(x => x.parent).Where(p => !ids.Contains(p)).Distinct().OrderBy(p => p)) Walk(root, 1);
            sb.Append("</DL><p>\n");
            File.WriteAllText(Path.Combine(folder, "Safari bookmarks.html"), sb.ToString(), new UTF8Encoding(false));
        }
        return n;
    }

    int ExportWhatsapp(string folder, Action<string> progress)
    {
        var db = Database(WhatsappDomain, "ChatStorage.sqlite");
        if (db == null || !HasTable(db, "ZWACHATSESSION")) return 0;
        var dir = Path.Combine(folder, "WhatsApp"); Directory.CreateDirectory(dir);
        var mediaDir = Path.Combine(dir, "Media");
        var media = new Dictionary<long, (string path, string title)>();
        if (HasTable(db, "ZWAMEDIAITEM"))
        {
            using var c = db.CreateCommand();
            c.CommandText = $"SELECT Z_PK, ZMEDIALOCALPATH, {Col(db, "ZWAMEDIAITEM", "ZTITLE")} FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH IS NOT NULL";
            using var r = c.ExecuteReader();
            while (r.Read()) media[r.GetInt64(0)] = (r.GetString(1), r.IsDBNull(2) ? "" : r.GetString(2));
        }
        var sessions = new List<(long id, string partner, string jid)>();
        using (var c = db.CreateCommand())
        {
            c.CommandText = $"SELECT Z_PK, {Col(db, "ZWACHATSESSION", "ZPARTNERNAME")}, {Col(db, "ZWACHATSESSION", "ZCONTACTJID")} FROM ZWACHATSESSION ORDER BY Z_PK";
            using var r = c.ExecuteReader();
            while (r.Read()) sessions.Add((r.GetInt64(0), r.IsDBNull(1) ? "" : r.GetString(1), r.IsDBNull(2) ? "" : r.GetString(2)));
        }
        var mcols = new[] { "ZTEXT", "ZMESSAGEDATE", "ZISFROMME", "ZFROMJID", "ZPUSHNAME", "ZMEDIAITEM", "ZMESSAGETYPE" };
        var namer = new Namer(); var copied = new HashSet<long>(); int total = 0;
        for (int i = 0; i < sessions.Count; i++)
        {
            var (sid, partnerName, jid) = sessions[i];
            var partner = partnerName != "" ? partnerName : jid.Contains('@') ? jid[..jid.IndexOf('@')] : jid != "" ? jid : $"Chat {sid}";
            progress($"WhatsApp: {partner} ({i + 1} of {sessions.Count})");
            var lines = new List<ChatLine>();
            using (var c = db.CreateCommand())
            {
                c.CommandText = $"SELECT Z_PK, {string.Join(", ", mcols.Select(x => Col(db, "ZWAMESSAGE", x)))} FROM ZWAMESSAGE WHERE ZCHATSESSION = {sid} ORDER BY ZMESSAGEDATE, Z_PK";
                using var r = c.ExecuteReader();
                while (r.Read())
                {
                    var text = r.IsDBNull(1) ? "" : r.GetString(1);
                    var date = r.IsDBNull(2) ? null : AppleDate(r.GetValue(2));
                    var fromMe = !r.IsDBNull(3) && Convert.ToInt64(r.GetValue(3)) != 0;
                    var fromJid = r.IsDBNull(4) ? "" : r.GetString(4);
                    var push = r.IsDBNull(5) ? "" : r.GetString(5);
                    var sender = fromMe ? "Me" : push != "" ? push : fromJid.Contains('@') ? fromJid[..fromJid.IndexOf('@')] : partner;
                    var atts = new List<(string, string)>();
                    if (!r.IsDBNull(6) && media.TryGetValue(Convert.ToInt64(r.GetValue(6)), out var m))
                    {
                        var mpk = Convert.ToInt64(r.GetValue(6));
                        var f = Find(WhatsappDomain, "Message/" + m.path) ?? Find(WhatsappDomain, m.path);
                        var name = m.title != "" ? m.title : m.path.Split('/').Last();
                        if (f != null)
                        {
                            var target = $"{mpk}_{Sanitize(m.path.Split('/').Last())}";
                            if (copied.Add(mpk)) { try { Extract(f, Path.Combine(mediaDir, target)); } catch { } }
                            atts.Add((name, "Media/" + target));
                        }
                        else atts.Add((name, $"(missing: {name})"));
                    }
                    var type = r.IsDBNull(7) ? 0 : Convert.ToInt64(r.GetValue(7));
                    if (text == "" && type != 0) text = "[media]";
                    lines.Add(new ChatLine(date, sender, text, atts));
                }
            }
            if (lines.Count == 0) continue;
            WriteChat(partner, lines, Path.Combine(dir, namer.Unique(Sanitize(partner), "")));
            total += lines.Count;
        }
        return total;
    }

    public void Dispose()
    {
        foreach (var c in dbCache.Values) c?.Dispose();
        dbCache.Clear();
        manifest?.Dispose(); manifest = null;
        SqliteConnection.ClearAllPools();
        try { Directory.Delete(scratch, true); } catch { }
    }
}
