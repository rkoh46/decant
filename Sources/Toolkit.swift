// Backup & Restore and Firmware: thin wrappers over the libimobiledevice family of tools. Every operation that
// changes the phone (restore, update, delete a backup) is started only from a confirmed UI action; this file
// never decides to run one on its own. Output streams into the log so the user can see exactly what ran.
import Foundation
import CryptoKit

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
        candidates += ["\(vendor.path)/tsschecker/\(name)", "\(vendor.path)/futurerestore/\(name)",
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

    static var defaultRoot: URL {
        let ext = URL(fileURLWithPath: "/Volumes/OS_Backups/Decant/Backups")
        if FileManager.default.fileExists(atPath: "/Volumes/OS_Backups") { return ext }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Decant Backups")
    }

    func scan(_ root: URL) {
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

    static let generator = "0x1111111111111111"      // the community convention; set this on the phone before a futurerestore
    /// ApNonce an A12+ chip derives from that generator: SHA-384 of the eight generator bytes, first 32 bytes.
    static var generatorNonce: String {
        let bytes = Data([0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11])
        return SHA384.hash(data: bytes).prefix(32).map { String(format: "%02x", $0) }.joined()
    }

    static var defaultRoot: URL {
        let ext = URL(fileURLWithPath: "/Volumes/OS_Backups/Decant")
        if FileManager.default.fileExists(atPath: "/Volumes/OS_Backups") { return ext }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Decant")
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

    func saveBlobs(ecid: String, productType: String, board: String, basebandSerial: String, root: URL) async {
        guard !running, Tools.has("tsschecker") else { log("tsschecker is not installed; blobs not saved"); return }
        running = true; phase = "Saving SHSH blobs"; progress = nil
        let dir = Self.blobDir(root, ecid: ecid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Try the versions ipsw.me calls signed plus the two newest, in case its flags are stale either way.
        var candidates = firmwares.filter { $0.signed }
        for fw in firmwares.prefix(2) where !candidates.contains(fw) { candidates.append(fw) }
        var saved = 0
        for fw in candidates {
            var args = ["-d", productType, "-B", board, "-e", ecid, "-i", fw.version, "--buildid", fw.buildid,
                        "-s", "--save-path", dir.path, "-g", Self.generator, "--apnonce", Self.generatorNonce]
            if !basebandSerial.isEmpty { args += ["--bbsnum", basebandSerial] } else { args.append("--no-baseband") }
            var signedNow: Bool?
            await Tools.stream("tsschecker", args) { [weak self] l in
                if l.contains("IS NOT signed") || l.contains("IS NOT being signed") { signedNow = false }
                else if l.contains("IS signed") || l.contains("IS being signed") { signedNow = true }
                if l.lowercased().contains("saved") || l.contains("Error") || l.contains("TSS server returned") { self?.log(l) }
            }
            if let v = signedNow { verdicts[fw.buildid] = v }
            if signedNow == true { saved += 1; log("Blob saved for iOS \(fw.version) (\(fw.buildid))") }
            else if signedNow == false { log("iOS \(fw.version) (\(fw.buildid)) is no longer signed, no blob") }
        }
        phase = saved > 0 ? "Blobs saved for \(saved) version\(saved == 1 ? "" : "s")" : "No signed version to save blobs for"
        running = false
        scanBlobs(root: root, ecid: ecid)
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
