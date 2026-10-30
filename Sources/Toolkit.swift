// Backup & Restore and Firmware: thin wrappers over the libimobiledevice family of tools. Every operation that
// changes the phone (restore, update, delete a backup) is started only from a confirmed UI action; this file
// never decides to run one on its own. Output streams into the log so the user can see exactly what ran.
import Foundation
import CryptoKit
import Compression

// MARK: - Tool locations and running

enum Tools {
    /// Bundled copies first (Contents/Helpers), then Homebrew, then the repo's vendor folder while developing.
    static func path(_ name: String) -> String? {
        var candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
                          "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        let vendor = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Decant/vendor")
        if name == "tsschecker", let found = FileManager.default.enumerator(atPath: "\(vendor.path)/tsschecker-new")?
            .compactMap({ $0 as? String }).first(where: { ($0 as NSString).lastPathComponent == "tsschecker" }) {
            candidates.insert("\(vendor.path)/tsschecker-new/\(found)", at: 0)
        }
        candidates += ["\(vendor.path)/bin/\(name)", "\(vendor.path)/tsschecker/\(name)", "\(vendor.path)/futurerestore/\(name)",
                       "\(vendor.path)/idevicerestore/src/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func has(_ name: String) -> Bool { path(name) != nil }

    /// Run a tool, streaming each output line (stdout and stderr merged) as it arrives. Returns the exit status,
    /// or nil when the tool is missing. `register` receives the Process so a caller can terminate it.
    @discardableResult
    static func stream(_ name: String, _ args: [String], input: String? = nil,
                       register: ((Process) -> Void)? = nil, line: @escaping (String) -> Void) async -> Int32? {
        guard let path = path(name) else { line("\(name) is not installed"); return nil }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            if let input {
                let inPipe = Pipe(); p.standardInput = inPipe
                inPipe.fileHandleForWriting.write(Data(input.utf8)); try? inPipe.fileHandleForWriting.close()
            }
            var buffer = Data()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                buffer.append(d)
                // Progress bars rewrite the line with \r; treat \r like a line break so percentages come through.
                while let r = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let chunk = buffer[buffer.startIndex..<r]
                    buffer.removeSubrange(buffer.startIndex...r)
                    if let s = String(data: chunk, encoding: .utf8), !s.trimmingCharacters(in: .whitespaces).isEmpty { line(s) }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let s = String(data: buffer, encoding: .utf8), !s.trimmingCharacters(in: .whitespaces).isEmpty { line(s) }
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run(); register?(p) } catch { line("could not start \(name): \(error.localizedDescription)"); cont.resume(returning: nil) }
        }
    }

    static func percent(in line: String) -> Double? {
        guard let r = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        return Double(line[r].dropLast()).map { $0 / 100 }
    }
}

// MARK: - BuildManifest straight out of a remote IPSW (HTTP ranges, so 12 GB is never downloaded)

enum ManifestFetcher {
    struct ZipError: Error, CustomStringConvertible { let description: String }

    static func fetch(ipsw: URL, member: String = "BuildManifest.plist") async throws -> Data {
        var head = URLRequest(url: ipsw); head.httpMethod = "HEAD"
        let (_, hr) = try await URLSession.shared.data(for: head)
        guard let size = (hr as? HTTPURLResponse).flatMap({ Int($0.value(forHTTPHeaderField: "Content-Length") ?? "") }), size > 0 else {
            throw ZipError(description: "no Content-Length for \(ipsw.lastPathComponent)")
        }
        func range(_ a: Int, _ b: Int) async throws -> Data {
            var r = URLRequest(url: ipsw); r.setValue("bytes=\(a)-\(b)", forHTTPHeaderField: "Range")
            return try await URLSession.shared.data(for: r).0
        }
        func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
        func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }
        func u64(_ d: Data, _ o: Int) -> Int { u32(d, o) | u32(d, o + 4) << 32 }

        let tail = try await range(max(0, size - 66000), size - 1)
        guard let eocd = tail.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06]))?.lowerBound else { throw ZipError(description: "no zip directory") }
        let e = eocd - tail.startIndex
        var cdCount = u16(tail, e + 10), cdSize = u32(tail, e + 12), cdOff = u32(tail, e + 16)
        if cdCount == 0xFFFF || cdSize == 0xFFFFFFFF || cdOff == 0xFFFFFFFF {
            guard let loc = tail.lastRange(of: Data([0x50, 0x4b, 0x06, 0x07]))?.lowerBound else { throw ZipError(description: "no zip64 locator") }
            let z64Off = u64(tail, loc - tail.startIndex + 8)
            let z64 = try await range(z64Off, z64Off + 55)
            cdCount = u64(z64, 32); cdSize = u64(z64, 40); cdOff = u64(z64, 48)
        }
        let cd = try await range(cdOff, cdOff + cdSize - 1)
        var pos = 0
        while pos + 46 <= cd.count {
            guard u32(cd, pos) == 0x02014b50 else { break }
            let method = u16(cd, pos + 10)
            var csize = u32(cd, pos + 20), usize = u32(cd, pos + 24)
            let nlen = u16(cd, pos + 28), elen = u16(cd, pos + 30), clen = u16(cd, pos + 32)
            var lho = u32(cd, pos + 42)
            let name = String(data: cd.subdata(in: cd.startIndex + pos + 46 ..< cd.startIndex + pos + 46 + nlen), encoding: .utf8) ?? ""
            if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF || lho == 0xFFFFFFFF {
                var x = pos + 46 + nlen
                let end = x + elen
                while x + 4 <= end {
                    let hid = u16(cd, x), hlen = u16(cd, x + 2)
                    if hid == 1 {
                        var o = x + 4
                        if usize == 0xFFFFFFFF { usize = u64(cd, o); o += 8 }
                        if csize == 0xFFFFFFFF { csize = u64(cd, o); o += 8 }
                        if lho == 0xFFFFFFFF { lho = u64(cd, o) }
                    }
                    x += 4 + hlen
                }
            }
            if name == member {
                let lh = try await range(lho, lho + 29)
                let start = lho + 30 + u16(lh, 26) + u16(lh, 28)
                let raw = try await range(start, start + csize - 1)
                if method == 0 { return raw }
                guard method == 8 else { throw ZipError(description: "unsupported compression \(method)") }
                var out = Data(count: usize)
                let n = out.withUnsafeMutableBytes { dst in
                    raw.withUnsafeBytes { src in
                        compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, usize,
                                                  src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard n == usize else { throw ZipError(description: "inflate failed") }
                return out
            }
            pos += 46 + nlen + elen + clen
        }
        throw ZipError(description: "\(member) not in the archive")
    }
}

// MARK: - Backups (idevicebackup2)

struct BackupInfo: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int
    let deviceName: String
    let version: String
    let encrypted: Bool
    var id: String { url.path }
}

@MainActor
final class BackupService: ObservableObject {
    @Published var backups: [BackupInfo] = []
    @Published var running = false
    @Published var phase = ""
    @Published var progress: Double?
    private var process: Process?
    var log: (String) -> Void = { _ in }

    /// Where backups go unless the user picks a folder: Documents/Decant/Backups (Windows: Documents\Decant\Backups).
    static var defaultRoot: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Decant/Backups")
    }

    /// Finder/iTunes backups live here; reading it needs Full Disk Access, which `finderBackupsReadable` reports.
    static let finderRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MobileSync/Backup")
    @Published var finderBackups: [BackupInfo] = []
    @Published var finderBackupsReadable = true

    /// Describe one backup folder (the <UDID> folder, or a folder that contains one). Nil when it is not a backup.
    func info(for folder: URL) -> BackupInfo? {
        let fm = FileManager.default
        var dir = folder
        if !fm.fileExists(atPath: dir.appendingPathComponent("Info.plist").path) {
            guard let sub = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("Info.plist").path) }) else { return nil }
            dir = sub
        }
        guard let info = plist(dir.appendingPathComponent("Info.plist")) else { return nil }
        let manifest = plist(dir.appendingPathComponent("Manifest.plist"))
        return BackupInfo(url: dir,
                          date: info["Last Backup Date"] as? Date ?? (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date ?? .distantPast,
                          size: Self.folderSize(dir),
                          deviceName: info["Device Name"] as? String ?? dir.lastPathComponent,
                          version: info["Product Version"] as? String ?? "",
                          encrypted: manifest?["IsEncrypted"] as? Bool ?? false)
    }

    func scanFinder() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.finderRoot, includingPropertiesForKeys: nil) else {
            finderBackupsReadable = !fm.fileExists(atPath: Self.finderRoot.path) ? true : false
            finderBackups = []
            return
        }
        finderBackupsReadable = true
        finderBackups = dirs.compactMap { info(for: $0) }.sorted { $0.date > $1.date }
    }

    func scan(_ root: URL) {
        scanFinder()
        let fm = FileManager.default
        var found: [BackupInfo] = []
        // idevicebackup2 writes <root>/<UDID>/{Info.plist, Manifest.plist, ...}; we also accept dated subfolders.
        for dir in Self.backupDirs(under: root) {
            guard let info = plist(dir.appendingPathComponent("Info.plist")) else { continue }
            let manifest = plist(dir.appendingPathComponent("Manifest.plist"))
            found.append(BackupInfo(
                url: dir,
                date: info["Last Backup Date"] as? Date ?? (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date ?? .distantPast,
                size: Self.folderSize(dir),
                deviceName: info["Device Name"] as? String ?? dir.lastPathComponent,
                version: info["Product Version"] as? String ?? "",
                encrypted: manifest?["IsEncrypted"] as? Bool ?? false))
        }
        backups = found.sorted { $0.date > $1.date }
    }

    private static func backupDirs(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var dirs: [URL] = []
        for u in top {
            if fm.fileExists(atPath: u.appendingPathComponent("Info.plist").path) { dirs.append(u); continue }
            if let sub = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil) {
                dirs += sub.filter { fm.fileExists(atPath: $0.appendingPathComponent("Info.plist").path) }
            }
        }
        return dirs
    }

    private func plist(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    static func folderSize(_ url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0 }
        return total
    }

    /// A full backup into <root>/<yyyy-MM-dd HHmm>/<UDID>. Encryption is turned on first when a password is given
    /// (that is what makes Health data, saved passwords and Wi-Fi settings part of the backup).
    func backup(udid: String, to root: URL, password: String?) async {
        guard !running else { return }
        running = true; progress = 0; phase = "Preparing"
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; return f.string(from: Date()) }()
        let dest = root.appendingPathComponent(stamp)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        log("Backup to \(dest.path)")
        if let password, !password.isEmpty {
            phase = "Turning on backup encryption"
            await Tools.stream("idevicebackup2", ["-u", udid, "encryption", "on", password]) { [weak self] l in self?.log(l) }
        }
        phase = "Backing up"
        let status = await Tools.stream("idevicebackup2", ["-u", udid, "backup", "--full", dest.path],
                                        register: { [weak self] p in self?.process = p }) { [weak self] l in
            guard let self else { return }
            if let pct = Tools.percent(in: l) { self.progress = pct } else { self.log(l) }
        }
        phase = status == 0 ? "Backup finished" : "Backup failed"
        log(phase)
        running = false; process = nil
        scan(root)
    }

    /// Restore a backup onto the phone. Replaces its current contents; the UI confirms twice before calling this.
    func restore(_ backup: BackupInfo, udid: String, password: String?) async {
        guard !running else { return }
        running = true; progress = 0; phase = "Restoring"
        log("Restore from \(backup.url.path)")
        var args = ["-u", udid, "restore", "--system", "--settings", "--reboot"]
        if let password, !password.isEmpty { args += ["--password", password] }
        // idevicebackup2 expects the folder that contains the <UDID> folder.
        args.append(backup.url.deletingLastPathComponent().path)
        let status = await Tools.stream("idevicebackup2", args, register: { [weak self] p in self?.process = p }) { [weak self] l in
            guard let self else { return }
            if let pct = Tools.percent(in: l) { self.progress = pct } else { self.log(l) }
        }
        phase = status == 0 ? "Restore finished, the iPhone is rebooting" : "Restore failed"
        log(phase)
        running = false; process = nil
    }

    func cancel() { process?.terminate() }

    func delete(_ backup: BackupInfo, root: URL) {
        // The dated folder that holds the <UDID> folder, when that is how it was laid out.
        var target = backup.url
        if target.deletingLastPathComponent().path != root.path { target = target.deletingLastPathComponent() }
        try? FileManager.default.trashItem(at: target, resultingItemURL: nil)
        scan(root)
    }
}

// MARK: - Firmware (ipsw.me, tsschecker, idevicerestore, irecovery, futurerestore)

struct Firmware: Identifiable, Hashable, Decodable {
    let version: String
    let buildid: String
    let url: URL
    let sha256: String?
    let filesize: Int
    let signed: Bool
    let releasedate: String
    var id: String { buildid }
}

struct BlobInfo: Identifiable, Hashable {
    let url: URL
    let version: String
    let build: String
    let generator: String?
    let date: Date
    var id: String { url.path }
}

enum RecoveryMode: String { case none = "Normal", recovery = "Recovery", dfu = "DFU", unknown = "Unknown", unavailable = "–" }

@MainActor
final class FirmwareService: ObservableObject {
    @Published var firmwares: [Firmware] = []
    @Published var blobs: [BlobInfo] = []
    @Published var running = false
    @Published var phase = ""
    @Published var progress: Double?
    @Published var mode: RecoveryMode = .none
    private var process: Process?
    var log: (String) -> Void = { _ in }

    nonisolated static let generator = "0x1111111111111111"      // the community convention; set this on the phone before a futurerestore
    nonisolated static func validGenerator(_ g: String) -> Bool {
        g.count == 18 && g.lowercased().hasPrefix("0x") && g.dropFirst(2).allSatisfy { $0.isHexDigit }
    }
    /// ApNonce an A12+ chip derives from that generator: SHA-384 of the eight generator bytes, first 32 bytes.
    static var generatorNonce: String {
        let bytes = Data([0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11])
        return SHA384.hash(data: bytes).prefix(32).map { String(format: "%02x", $0) }.joined()
    }

    /// Blobs, manifests and IPSWs go to Documents/Decant unless the user picks a folder.
    static var defaultRoot: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Decant")
    }
    static func blobDir(_ root: URL, ecid: String) -> URL { root.appendingPathComponent("Blobs/\(ecid)") }
    static func ipswDir(_ root: URL) -> URL { root.appendingPathComponent("IPSW") }

    // Signing status from ipsw.me, which mirrors Apple's TSS answers per model.
    func loadSigning(productType: String) async {
        guard let u = URL(string: "https://api.ipsw.me/v4/device/\(productType)?type=ipsw") else { return }
        struct Reply: Decodable { let firmwares: [Firmware] }
        do {
            let (d, _) = try await URLSession.shared.data(from: u)
            firmwares = try JSONDecoder().decode(Reply.self, from: d).firmwares
        } catch { log("Could not load signing status: \(error.localizedDescription)") }
    }

    func scanBlobs(root: URL, ecid: String) {
        let dir = Self.blobDir(root, ecid: ecid)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        blobs = files.filter { $0.pathExtension == "shsh2" }.map { f in
            // tsschecker names files <ecid>_<model>_<board>_<version>-<build>_<generator>.shsh2
            let parts = f.deletingPathExtension().lastPathComponent.split(separator: "_").map(String.init)
            let vb = parts.count > 3 ? parts[3].split(separator: "-").map(String.init) : []
            return BlobInfo(url: f, version: vb.first ?? "?", build: vb.count > 1 ? vb[1] : "",
                            generator: parts.count > 4 ? parts[4] : nil,
                            date: (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    /// Save blobs for every version Apple currently signs, with the fixed generator. Safe to run every time the
    /// phone connects: tsschecker overwrites nothing and Apple's TSS answers are cheap.
    /// Versions tsschecker itself reported as signed or unsigned; Apple's TSS is the truth, ipsw.me can lag.
    @Published var verdicts: [String: Bool] = [:]

    func saveBlobs(ecid: String, productType: String, board: String, basebandSerial: String, basebandCert: String, root: URL, generator: String = FirmwareService.generator) async {
        guard !running, Tools.has("decant-tss") else { log("The blob saver is missing from this build"); return }
        running = true; phase = "Saving SHSH blobs"; progress = nil
        let dir = Self.blobDir(root, ecid: ecid)
        let manifests = root.appendingPathComponent("Manifests")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        // Ask Apple about what ipsw.me calls signed plus the two newest builds; Apple's answer is what counts.
        var candidates = firmwares.filter { $0.signed }
        for fw in firmwares.prefix(2) where !candidates.contains(fw) { candidates.append(fw) }
        var saved = 0, kept = 0
        for fw in candidates {
            let manifest = manifests.appendingPathComponent("\(productType)_\(fw.buildid).plist")
            if !FileManager.default.fileExists(atPath: manifest.path) {
                phase = "Reading the iOS \(fw.version) manifest"
                do { try (try await ManifestFetcher.fetch(ipsw: fw.url)).write(to: manifest) }
                catch { log("Could not read the manifest for iOS \(fw.version): \(error)"); continue }
            }
            let out = dir.appendingPathComponent("\(ecid)_\(productType)_\(board)_\(fw.version)-\(fw.buildid)_\(generator).shsh2")
            // A saved blob is irreplaceable once Apple stops signing that build: never ask again and never overwrite it.
            if let size = try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int, size > 0 {
                verdicts[fw.buildid] = true; kept += 1
                log("Blob for iOS \(fw.version) (\(fw.buildid)) is already saved; keeping it")
                continue
            }
            phase = "Asking Apple about iOS \(fw.version)"
            var args = ["--manifest", manifest.path, "--board", board, "--ecid", ecid, "--generator", generator, "--out", out.path]
            if !basebandSerial.isEmpty && !basebandCert.isEmpty { args += ["--bbsnum", basebandSerial, "--bbcert", basebandCert] }
            let status = await Tools.stream("decant-tss", args) { [weak self] l in if l.contains("error") { self?.log(l) } }
            switch status {
            case 0:
                verdicts[fw.buildid] = true; saved += 1; log("Blob saved for iOS \(fw.version) (\(fw.buildid))")
                Self.protect(out)
            case 3: verdicts[fw.buildid] = false; log("iOS \(fw.version) (\(fw.buildid)) is no longer signed")
            default: log("Blob request for iOS \(fw.version) failed")
            }
        }
        phase = saved > 0 ? "Blobs saved for \(saved) version\(saved == 1 ? "" : "s")"
              : kept > 0 ? "Blobs already saved for \(kept) version\(kept == 1 ? "" : "s")" : "No signed version to save blobs for"
        running = false
        scanBlobs(root: root, ecid: ecid)
    }

    /// Read-only and locked in Finder, so a stray delete or overwrite asks first.
    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o444, .immutable: true], ofItemAtPath: url.path)
    }

    func isSigned(_ fw: Firmware) -> Bool { verdicts[fw.buildid] ?? fw.signed }

    func downloadIPSW(_ fw: Firmware, root: URL) async -> URL? {
        guard !running else { return nil }
        running = true; phase = "Downloading iOS \(fw.version)"; progress = 0
        let dir = Self.ipswDir(root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fw.url.lastPathComponent)
        defer { running = false }
        if FileManager.default.fileExists(atPath: dest.path), (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int == fw.filesize {
            phase = "Already downloaded"; return dest
        }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: fw.url, delegate: nil)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            phase = "Downloaded"
            log("IPSW saved to \(dest.path)")
            return dest
        } catch {
            phase = "Download failed"; log("IPSW download failed: \(error.localizedDescription)"); return nil
        }
    }

    func refreshMode() async {
        var out = ""
        guard Tools.has("irecovery") else { mode = .unavailable; return }
        let status = await Tools.stream("irecovery", ["-q"]) { out += $0 + "\n" }
        if status == nil { mode = .none; return }
        if let r = out.range(of: #"MODE:\s*(\w+)"#, options: .regularExpression) {
            let m = out[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            mode = m.localizedCaseInsensitiveContains("dfu") ? .dfu : m.localizedCaseInsensitiveContains("recovery") ? .recovery : .unknown
        } else { mode = .none }
    }

    func enterRecovery(udid: String) async {
        log("Entering recovery mode")
        await Tools.stream("ideviceenterrecovery", [udid]) { [weak self] in self?.log($0) }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await refreshMode()
    }

    func exitRecovery() async {
        log("Leaving recovery mode")
        await Tools.stream("irecovery", ["-n"]) { [weak self] in self?.log($0) }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await refreshMode()
    }

    /// Restore (erase) or update (keep data) to a signed IPSW. The UI has confirmed twice and named the version.
    func restore(ipsw: URL, erase: Bool) async {
        guard !running else { return }
        running = true; progress = 0; phase = erase ? "Restoring (erase)" : "Updating (keep data)"
        log("\(phase) with \(ipsw.lastPathComponent)")
        let status = await Tools.stream("idevicerestore", [erase ? "-e" : "-u", "-y", ipsw.path],
                                        register: { [weak self] p in self?.process = p }) { [weak self] l in
            guard let self else { return }
            if let pct = Tools.percent(in: l) { self.progress = pct }
            self.log(l)
        }
        phase = status == 0 ? "Restore finished" : "Restore failed"
        running = false; process = nil
    }

    /// Restore to an unsigned version using a saved blob. Needs the phone's nonce to match the blob's generator,
    /// which on A12 and newer is set from a jailbreak; the UI explains this before enabling the button.
    func futureRestore(blob: URL, ipsw: URL, erase: Bool) async {
        guard !running else { return }
        running = true; progress = 0; phase = "futurerestore"
        var args = ["-t", blob.path, "--latest-sep", "--latest-baseband"]
        if erase { args.append("--erase") }
        args.append(ipsw.path)
        log("futurerestore \(args.joined(separator: " "))")
        let status = await Tools.stream("futurerestore", args, register: { [weak self] p in self?.process = p }) { [weak self] l in
            guard let self else { return }
            if let pct = Tools.percent(in: l) { self.progress = pct }
            self.log(l)
        }
        phase = status == 0 ? "futurerestore finished" : "futurerestore failed"
        running = false; process = nil
    }

    func cancel() { process?.terminate() }
}
