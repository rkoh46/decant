// Firmware: what Apple is signing (ipsw.me), SHSH blobs saved from Apple's signing server for later restores, IPSW
// downloads, and restores through idevicerestore. Mirrors FirmwareService in the Mac's Toolkit.swift; the Mac's
// decant-tss helper (libtatsu) is replaced by Tss below, Decant's own TSS request in C#.
using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Decant.Engine;

public sealed record Firmware(string Version, string BuildId, string Url, string? Sha256, long FileSize, bool Signed, string ReleaseDate)
{
    public string Id => BuildId;
}

public sealed record BlobInfo(string Path, string Version, string Build, string? Generator, DateTime Date)
{
    public string Id => Path;
}

public enum RecoveryMode { None, Recovery, Dfu, Unknown, Unavailable }

public static class RecoveryModeText
{
    public static string Text(this RecoveryMode m) => m switch { RecoveryMode.None => "Normal", RecoveryMode.Recovery => "Recovery", RecoveryMode.Dfu => "DFU", RecoveryMode.Unknown => "Unknown", _ => "–" };
}

public sealed class FirmwareService
{
    public const string Generator = "0x1111111111111111";
    public static string DefaultRoot => Path.Combine(Prefs.Documents, "Decant");
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(30) };

    public List<Firmware> Firmwares = new();
    public List<BlobInfo> Blobs = new();
    public Dictionary<string, bool> Verdicts = new();
    public RecoveryMode Mode = RecoveryMode.None;
    public bool Running;
    public string Phase = "";
    public double? Progress;
    public Action<string> Log = _ => { };
    public event Action? Changed;
    Process? process;
    void Notify() => Changed?.Invoke();

    public static bool ValidGenerator(string g) => g.Length == 18 && g.StartsWith("0x", StringComparison.OrdinalIgnoreCase) && g[2..].All(Uri.IsHexDigit);
    public bool IsSigned(Firmware fw) => Verdicts.TryGetValue(fw.BuildId, out var v) ? v : fw.Signed;
    public static string BlobDir(string root, string ecid) => Path.Combine(root, "Blobs", ecid);
    public static string IpswDir(string root) => Path.Combine(root, "IPSW");
    public static string IpswPath(string root, Firmware fw) => Path.Combine(IpswDir(root), fw.Url.Split('/').Last());
    public static bool HasBlobSaver => true;   // the TSS request is built in

    // MARK: Signing status

    public async Task LoadSigning(string productType)
    {
        if (Session.Demo)
        {
            Firmwares = DemoFirmware.Firmwares();
            foreach (var f in Firmwares) if (f.Signed) Verdicts[f.BuildId] = true;
            Notify(); return;
        }
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"https://api.ipsw.me/v4/device/{productType}?type=ipsw");
            req.Headers.UserAgent.ParseAdd("Decant/1.0");
            var json = await http.GetStringAsync(req.RequestUri!);
            using var doc = JsonDocument.Parse(json);
            var list = new List<Firmware>();
            foreach (var f in doc.RootElement.GetProperty("firmwares").EnumerateArray())
            {
                string S(string k) => f.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
                list.Add(new Firmware(S("version"), S("buildid"), S("url"), S("sha256") == "" ? null : S("sha256"),
                    f.TryGetProperty("filesize", out var fs) && fs.ValueKind == JsonValueKind.Number ? fs.GetInt64() : 0,
                    f.TryGetProperty("signed", out var sg) && sg.ValueKind == JsonValueKind.True, S("releasedate")));
            }
            Firmwares = list;
        }
        catch (Exception e) { Log($"Could not load signing status: {e.Message}"); }
        Notify();
    }

    // MARK: Blobs on disk

    public void ScanBlobs(string root, string ecid)
    {
        if (Session.Demo) { Blobs = DemoFirmware.Blobs(); Notify(); return; }
        var list = new List<BlobInfo>();
        var dir = BlobDir(root, ecid);
        if (Directory.Exists(dir))
            foreach (var f in Directory.EnumerateFiles(dir, "*.shsh2"))
            {
                var parts = Path.GetFileNameWithoutExtension(f).Split('_');
                var vb = parts.Length > 3 ? parts[3].Split('-') : Array.Empty<string>();
                list.Add(new BlobInfo(f, vb.Length > 0 ? vb[0] : "?", vb.Length > 1 ? vb[1] : "", parts.Length > 4 ? parts[4] : null, File.GetLastWriteTime(f)));
            }
        Blobs = list.OrderByDescending(b => b.Date).ToList();
        Notify();
    }

    public async Task SaveBlobs(string ecid, string productType, string board, string basebandSerial, string basebandCert, string root, string generator)
    {
        if (Session.Demo) { Phase = "Blobs already saved for 2 versions"; Notify(); return; }
        if (Running) return;
        Running = true; Phase = "Saving SHSH blobs"; Progress = null; Notify();
        var blobDir = BlobDir(root, ecid); var manifests = Path.Combine(root, "Manifests");
        Directory.CreateDirectory(blobDir); Directory.CreateDirectory(manifests);
        var candidates = Firmwares.Where(f => f.Signed).ToList();
        foreach (var f in Firmwares.Take(2)) if (!candidates.Contains(f)) candidates.Add(f);
        int saved = 0, kept = 0;
        foreach (var fw in candidates)
        {
            var manifest = Path.Combine(manifests, $"{productType}_{fw.BuildId}.plist");
            if (!File.Exists(manifest))
            {
                Phase = $"Reading the iOS {fw.Version} manifest"; Notify();
                try { File.WriteAllBytes(manifest, await ManifestFetcher.Fetch(fw.Url)); }
                catch (Exception e) { Log($"Could not read the manifest for iOS {fw.Version}: {e.Message}"); continue; }
            }
            var outPath = Path.Combine(blobDir, $"{ecid}_{productType}_{board}_{fw.Version}-{fw.BuildId}_{generator}.shsh2");
            if (File.Exists(outPath) && new FileInfo(outPath).Length > 0)
            {
                Verdicts[fw.BuildId] = true; kept++;
                Log($"Blob for iOS {fw.Version} ({fw.BuildId}) is already saved; keeping it");
                continue;
            }
            Phase = $"Asking Apple about iOS {fw.Version}"; Notify();
            int code;
            try { code = await Tss.Save(manifest, board, ecid, generator, basebandSerial, basebandCert, outPath, Log); }
            catch (Exception e) { Log($"error: {e.Message}"); code = 1; }
            if (code == 0)
            {
                Verdicts[fw.BuildId] = true; saved++;
                Log($"Blob saved for iOS {fw.Version} ({fw.BuildId})");
                try { File.SetAttributes(outPath, File.GetAttributes(outPath) | FileAttributes.ReadOnly); } catch { }
            }
            else if (code == 3) { Verdicts[fw.BuildId] = false; Log($"iOS {fw.Version} ({fw.BuildId}) is no longer signed"); }
            else Log($"Blob request for iOS {fw.Version} failed");
        }
        Phase = saved > 0 ? $"Blobs saved for {saved} version{(saved == 1 ? "" : "s")}" : kept > 0 ? $"Blobs already saved for {kept} version{(kept == 1 ? "" : "s")}" : "No signed version to save blobs for";
        Running = false; Notify();
        ScanBlobs(root, ecid);
    }

    // MARK: IPSW

    public async Task DownloadIpsw(Firmware fw, string root)
    {
        if (Running) return;
        Running = true; Phase = $"Downloading iOS {fw.Version}"; Progress = 0; Notify();
        var dest = IpswPath(root, fw);
        try
        {
            if (File.Exists(dest) && new FileInfo(dest).Length == fw.FileSize) { Phase = "Already downloaded"; return; }
            Directory.CreateDirectory(IpswDir(root));
            var tmp = dest + ".part";
            using (var resp = await http.GetAsync(fw.Url, HttpCompletionOption.ResponseHeadersRead))
            {
                resp.EnsureSuccessStatusCode();
                var total = resp.Content.Headers.ContentLength ?? fw.FileSize;
                using var src = await resp.Content.ReadAsStreamAsync();
                using var dst = File.Create(tmp);
                var buf = new byte[1 << 20]; long done = 0; int n; var last = DateTime.Now;
                while ((n = await src.ReadAsync(buf)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n)); done += n;
                    if (total > 0 && (DateTime.Now - last).TotalMilliseconds > 250) { Progress = (double)done / total; last = DateTime.Now; Notify(); }
                }
            }
            File.Move(tmp, dest, true);
            Phase = "Downloaded"; Log($"IPSW saved to {dest}");
        }
        catch (Exception e) { Phase = "Download failed"; Log($"IPSW download failed: {e.Message}"); }
        finally { Running = false; Progress = null; Notify(); }
    }

    // MARK: Recovery and restore

    public async Task RefreshMode()
    {
        if (Session.Demo) { Mode = RecoveryMode.None; Notify(); return; }
        if (!Tools.Has("irecovery")) { Mode = RecoveryMode.Unavailable; Notify(); return; }
        var sb = new StringBuilder();
        var code = await ToolsStream.Stream("irecovery", new[] { "-q" }, l => sb.AppendLine(l));
        if (code == null) { Mode = RecoveryMode.None; Notify(); return; }
        var m = Regex.Match(sb.ToString(), @"MODE:\s*(\w+)");
        Mode = !m.Success ? RecoveryMode.None : m.Groups[1].Value.Contains("dfu", StringComparison.OrdinalIgnoreCase) ? RecoveryMode.Dfu
            : m.Groups[1].Value.Contains("recovery", StringComparison.OrdinalIgnoreCase) ? RecoveryMode.Recovery : RecoveryMode.Unknown;
        Notify();
    }

    public async Task EnterRecovery(string udid)
    {
        Log("Entering recovery mode");
        await ToolsStream.Stream("ideviceenterrecovery", new[] { udid }, Log);
        await Task.Delay(3000);
        await RefreshMode();
    }

    public async Task ExitRecovery()
    {
        Log("Leaving recovery mode");
        await ToolsStream.Stream("irecovery", new[] { "-n" }, Log);
        await Task.Delay(3000);
        await RefreshMode();
    }

    public async Task Restore(string ipsw, bool erase)
    {
        if (Running) return;
        Running = true; Progress = 0; Phase = erase ? "Restoring (erase)" : "Updating (keep data)"; Notify();
        Log($"{Phase} with {Path.GetFileName(ipsw)}");
        var code = await ToolsStream.Stream("idevicerestore", new[] { erase ? "-e" : "-u", "-y", ipsw }, line =>
        {
            if (ToolsStream.Percent(line) is double p) { Progress = p; Notify(); }
            Log(line);
        }, register: p => process = p);
        process = null;
        Phase = code == 0 ? "Restore finished" : "Restore failed";
        Running = false; Notify();
    }

    public async Task FutureRestore(string blob, string ipsw, bool erase)
    {
        if (Running) return;
        Running = true; Progress = 0; Phase = "futurerestore"; Notify();
        var args = new List<string> { "-t", blob, "--latest-sep", "--latest-baseband" };
        if (erase) args.Add("--erase");
        args.Add(ipsw);
        Log("futurerestore " + string.Join(" ", args));
        var code = await ToolsStream.Stream("futurerestore", args, line =>
        {
            if (ToolsStream.Percent(line) is double p) { Progress = p; Notify(); }
            Log(line);
        }, register: p => process = p);
        process = null;
        Phase = code == 0 ? "futurerestore finished" : "futurerestore failed";
        Running = false; Notify();
    }

    public void Cancel() { try { process?.Kill(true); } catch { } }
}

/// Reads one member (BuildManifest.plist) out of a remote IPSW with HTTP range requests, so a 12 GB firmware is
/// never downloaded just to read its manifest. Mirrors tools/fetch_manifest.py.
public static class ManifestFetcher
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(5) };

    static async Task<byte[]> Range(string url, long start, long end)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(start, end);
        req.Headers.UserAgent.ParseAdd("Decant/1.0");
        using var resp = await http.SendAsync(req);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadAsByteArrayAsync();
    }

    public static async Task<byte[]> Fetch(string url, string member = "BuildManifest.plist")
    {
        long size;
        using (var head = new HttpRequestMessage(HttpMethod.Head, url))
        {
            head.Headers.UserAgent.ParseAdd("Decant/1.0");
            using var resp = await http.SendAsync(head);
            size = resp.Content.Headers.ContentLength ?? throw new Exception($"no Content-Length for {Path.GetFileName(url)}");
        }
        var tail = await Range(url, Math.Max(0, size - 66000), size - 1);
        int eocd = LastIndexOf(tail, new byte[] { 0x50, 0x4B, 0x05, 0x06 });
        if (eocd < 0) throw new Exception("no zip directory");
        long count = BinaryPrimitives.ReadUInt16LittleEndian(tail.AsSpan(eocd + 10));
        long cdSize = BinaryPrimitives.ReadUInt32LittleEndian(tail.AsSpan(eocd + 12));
        long cdOff = BinaryPrimitives.ReadUInt32LittleEndian(tail.AsSpan(eocd + 16));
        if (cdOff == 0xFFFFFFFF || cdSize == 0xFFFFFFFF || count == 0xFFFF)
        {
            int loc = LastIndexOf(tail, new byte[] { 0x50, 0x4B, 0x06, 0x07 });
            if (loc < 0) throw new Exception("no zip64 locator");
            var z64Off = (long)BinaryPrimitives.ReadUInt64LittleEndian(tail.AsSpan(loc + 8));
            var z64 = await Range(url, z64Off, z64Off + 55);
            count = (long)BinaryPrimitives.ReadUInt64LittleEndian(z64.AsSpan(32));
            cdSize = (long)BinaryPrimitives.ReadUInt64LittleEndian(z64.AsSpan(40));
            cdOff = (long)BinaryPrimitives.ReadUInt64LittleEndian(z64.AsSpan(48));
        }
        var cd = await Range(url, cdOff, cdOff + cdSize - 1);
        int pos = 0;
        while (pos + 46 <= cd.Length)
        {
            if (BinaryPrimitives.ReadUInt32LittleEndian(cd.AsSpan(pos)) != 0x02014b50) break;
            int method = BinaryPrimitives.ReadUInt16LittleEndian(cd.AsSpan(pos + 10));
            long csize = BinaryPrimitives.ReadUInt32LittleEndian(cd.AsSpan(pos + 20));
            long usize = BinaryPrimitives.ReadUInt32LittleEndian(cd.AsSpan(pos + 24));
            int nlen = BinaryPrimitives.ReadUInt16LittleEndian(cd.AsSpan(pos + 28));
            int elen = BinaryPrimitives.ReadUInt16LittleEndian(cd.AsSpan(pos + 30));
            int clen = BinaryPrimitives.ReadUInt16LittleEndian(cd.AsSpan(pos + 32));
            long lho = BinaryPrimitives.ReadUInt32LittleEndian(cd.AsSpan(pos + 42));
            var name = Encoding.UTF8.GetString(cd, pos + 46, nlen);
            var extra = cd.AsSpan(pos + 46 + nlen, elen);
            if (csize == 0xFFFFFFFF || usize == 0xFFFFFFFF || lho == 0xFFFFFFFF)
            {
                int e = 0;
                while (e + 4 <= extra.Length)
                {
                    int hid = BinaryPrimitives.ReadUInt16LittleEndian(extra[e..]), hlen = BinaryPrimitives.ReadUInt16LittleEndian(extra[(e + 2)..]);
                    var body = extra.Slice(e + 4, Math.Min(hlen, extra.Length - e - 4)).ToArray(); e += 4 + hlen;
                    if (hid != 1) continue;
                    int b = 0;
                    if (usize == 0xFFFFFFFF && b + 8 <= body.Length) { usize = (long)BinaryPrimitives.ReadUInt64LittleEndian(body.AsSpan(b)); b += 8; }
                    if (csize == 0xFFFFFFFF && b + 8 <= body.Length) { csize = (long)BinaryPrimitives.ReadUInt64LittleEndian(body.AsSpan(b)); b += 8; }
                    if (lho == 0xFFFFFFFF && b + 8 <= body.Length) { lho = (long)BinaryPrimitives.ReadUInt64LittleEndian(body.AsSpan(b)); b += 8; }
                }
            }
            if (name == member)
            {
                var lh = await Range(url, lho, lho + 29);
                int n2 = BinaryPrimitives.ReadUInt16LittleEndian(lh.AsSpan(26)), e2 = BinaryPrimitives.ReadUInt16LittleEndian(lh.AsSpan(28));
                var start = lho + 30 + n2 + e2;
                var data = await Range(url, start, start + csize - 1);
                if (method == 8)
                {
                    using var inflate = new DeflateStream(new MemoryStream(data), CompressionMode.Decompress);
                    using var o = new MemoryStream();
                    try { inflate.CopyTo(o); } catch { throw new Exception("inflate failed"); }
                    data = o.ToArray();
                }
                else if (method != 0) throw new Exception($"unsupported compression {method}");
                return data;
            }
            pos += 46 + nlen + elen + clen;
        }
        throw new Exception($"{member} not in the archive");
    }

    static int LastIndexOf(byte[] hay, byte[] needle)
    {
        for (int i = hay.Length - needle.Length; i >= 0; i--) if (hay.AsSpan(i, needle.Length).SequenceEqual(needle)) return i;
        return -1;
    }
}

/// Asks Apple's signing server (TSS) for a ticket and saves it as an .shsh2 blob: Decant's own port of
/// tools/decant-tss.c. Nothing here touches the phone; it needs only the identifiers read from it.
/// Returns 0 when saved, 3 when Apple refused (not signed), 1 on any other error. Never overwrites a blob.
public static class Tss
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(2) };

    public static async Task<int> Save(string manifestPath, string board, string ecid, string generator, string bbsnum, string bbcert, string outPath, Action<string> log, bool update = false)
    {
        if (File.Exists(outPath)) { log("error: refusing to overwrite an existing blob"); return 1; }
        if (BinaryPlist.ParseAny(File.ReadAllBytes(manifestPath)) is not Dictionary<string, object?> manifest) { log("error: cannot read the BuildManifest"); return 1; }
        var identity = (manifest.GetValueOrDefault("BuildIdentities") as List<object?>)?.OfType<Dictionary<string, object?>>().FirstOrDefault(bi =>
            bi.GetValueOrDefault("Info") is Dictionary<string, object?> info
            && string.Equals(Plist.Str(info.GetValueOrDefault("DeviceClass")), board, StringComparison.OrdinalIgnoreCase)
            && string.Equals(Plist.Str(info.GetValueOrDefault("RestoreBehavior")), update ? "Update" : "Erase", StringComparison.OrdinalIgnoreCase));
        if (identity == null) { log("error: no build identity for that board in the manifest"); return 1; }

        // ApNonce from the generator the way A12 and later chips derive it: SHA-384 of the 8 bytes, first 32.
        var gen = Convert.FromHexString(generator[2..]);
        if (gen.Length != 8) { log("error: generator must be 8 bytes, like 0x1111111111111111"); return 1; }
        var nonce = SHA384.HashData(gen)[..32];
        var sepNonce = RandomNumberGenerator.GetBytes(20);

        var request = new Dictionary<string, object?>
        {
            ["@HostPlatformInfo"] = "mac",
            ["@VersionInfo"] = "libauthinstall-1033.0.2",
            ["@UUID"] = Guid.NewGuid().ToString().ToUpperInvariant(),
            ["@ApImg4Ticket"] = true,
            ["ApECID"] = long.Parse(ecid, CultureInfo.InvariantCulture),
            ["ApNonce"] = nonce,
            ["ApSepNonce"] = sepNonce,
            ["SepNonce"] = sepNonce,
            ["ApProductionMode"] = true,
            ["ApSecurityMode"] = true,
        };
        long Hex(object? v) { var s = Plist.Str(v); return s.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? Convert.ToInt64(s[2..], 16) : long.TryParse(s, out var n) ? n : 0; }
        request["ApBoardID"] = Hex(identity.GetValueOrDefault("ApBoardID"));
        request["ApChipID"] = Hex(identity.GetValueOrDefault("ApChipID"));
        request["ApSecurityDomain"] = Hex(identity.GetValueOrDefault("ApSecurityDomain"));
        if (identity.GetValueOrDefault("UniqueBuildID") is byte[] ubid) request["UniqueBuildID"] = ubid;
        foreach (var k in new[] { "Ap,OSLongVersion", "Ap,ProductMarketingVersion", "Ap,ProductType", "Ap,SDKPlatform", "Ap,Target", "Ap,TargetType", "ApSikaFuse" })
            if (identity.TryGetValue(k, out var v) && v != null) request[k] = v is string s && s.StartsWith("0x") ? Hex(s) : v;

        var parameters = new Dictionary<string, object?> { ["ApProductionMode"] = true, ["ApSecurityMode"] = true, ["ApSupportsImg4"] = true, ["ApRawProductionMode"] = true, ["ApCurrentProductionMode"] = true, ["ApRawSecurityMode"] = true, ["ApRequiresImage4"] = true, ["ApDemotionPolicyOverride"] = false, ["ApInRomDFU"] = false };
        var hasBaseband = bbsnum != "" && bbcert != "";
        if (identity.GetValueOrDefault("Manifest") is Dictionary<string, object?> entries)
            foreach (var (key, val) in entries)
            {
                if (val is not Dictionary<string, object?> entry) continue;
                if (key == "BasebandFirmware") continue;
                if (entry.GetValueOrDefault("Info") is not Dictionary<string, object?> info) continue;
                var copy = entry.Where(kv => kv.Key != "Info").ToDictionary(kv => kv.Key, kv => kv.Value);
                if (info.GetValueOrDefault("RestoreRequestRules") is List<object?> rules)
                    foreach (var rule in rules.OfType<Dictionary<string, object?>>())
                    {
                        if (rule.GetValueOrDefault("Conditions") is not Dictionary<string, object?> conds || rule.GetValueOrDefault("Actions") is not Dictionary<string, object?> actions) continue;
                        var match = conds.All(c => parameters.TryGetValue(c.Key, out var pv) && Equals(pv, c.Value));
                        if (match) foreach (var (ak, av) in actions) copy[ak] = av;
                    }
                request[key] = copy;
            }
        if (hasBaseband)
        {
            request["@BBTicket"] = true;
            request["BbNonce"] = RandomNumberGenerator.GetBytes(20);
            request["BbGoldCertId"] = long.Parse(bbcert, CultureInfo.InvariantCulture);
            request["BbSNUM"] = Convert.FromHexString(bbsnum.StartsWith("0x") ? bbsnum[2..] : bbsnum);
            foreach (var k in new[] { "BbChipID", "BbProvisioningManifestKeyHash", "BbActivationManifestKeyHash", "BbCalibrationManifestKeyHash", "BbFactoryActivationManifestKeyHash", "BbFDRSecurityKeyHash", "BbSkeyId" })
                if (identity.TryGetValue(k, out var v) && v != null) request[k] = v is string s && s.StartsWith("0x") ? Hex(s) : v;
            if (identity.GetValueOrDefault("Manifest") is Dictionary<string, object?> m2 && m2.GetValueOrDefault("BasebandFirmware") is Dictionary<string, object?> bb)
                request["BasebandFirmware"] = bb.Where(kv => kv.Key != "Info").ToDictionary(kv => kv.Key, kv => kv.Value);
        }

        var xml = Plist.ToXml(request);
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://gs.apple.com/TSS/controller?action=2");
        req.Headers.UserAgent.ParseAdd("InetURL/1.0");
        req.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };
        req.Content = new StringContent(xml, Encoding.UTF8, "text/xml");
        string body;
        try { using var resp = await http.SendAsync(req); body = await resp.Content.ReadAsStringAsync(); }
        catch (Exception e) { log($"error: {e.Message}"); return 1; }
        var status = Regex.Match(body, @"STATUS=(\d+)");
        var at = body.IndexOf("REQUEST_STRING=", StringComparison.Ordinal);
        if (!status.Success || status.Groups[1].Value != "0" || at < 0)
        {
            var msg = Regex.Match(body, @"MESSAGE=([^&\r\n]*)");
            log($"not signed (the signing server refused the request{(msg.Success ? ": " + msg.Groups[1].Value : "")})");
            return 3;
        }
        var responseXml = body[(at + "REQUEST_STRING=".Length)..];
        if (Plist.Parse(responseXml) is not Dictionary<string, object?> response) { log("error: unreadable ticket"); return 1; }
        response["generator"] = generator;
        Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
        File.WriteAllText(outPath, Plist.ToXml(response), new UTF8Encoding(false));
        var ticket = response.GetValueOrDefault("ApImg4Ticket") as byte[];
        log($"signed: ticket {ticket?.Length ?? 0} bytes saved to {outPath}");
        return 0;
    }
}

public static class DemoFirmware
{
    const string Ecid = "1234567890123456";
    static Firmware Fw(string v, string b, bool signed, string date, double gb) =>
        new(v, b, $"https://updates.cdn-apple.com/iPhone17,2_{v}_{b}_Restore.ipsw", null, (long)(gb * 1_000_000_000), signed, date);

    public static List<Firmware> Firmwares() => new()
    {
        Fw("26.1", "23B85", true, "2026-11-03", 7.9), Fw("26.0.1", "23A355", true, "2026-09-29", 7.8), Fw("26.0", "23A341", false, "2026-09-15", 7.8),
        Fw("18.6.2", "22G100", false, "2026-08-20", 7.1), Fw("18.6", "22G86", false, "2026-07-29", 7.1), Fw("18.5", "22F76", false, "2026-05-12", 7.0),
    };

    public static List<BlobInfo> Blobs() => new[] { ("26.1", "23B85", 1.0), ("26.0.1", "23A355", 31.0), ("26.0", "23A341", 45.0), ("18.6.2", "22G100", 70.0) }
        .Select(t => new BlobInfo(Path.Combine(Prefs.Documents, "Decant", "Blobs", Ecid, $"{Ecid}_iPhone17,2_D94AP_{t.Item1}-{t.Item2}_0x1111111111111111.shsh2"),
            t.Item1, t.Item2, "0x1111111111111111", DateTime.Now.AddDays(-t.Item3))).ToList();
}
