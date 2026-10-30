// The phone side: Apple's Image Capture framework (what Image Capture.app and Photos use) lists the
// camera roll over USB, downloads files and deletes them. Every change to published state happens on
// the main thread; the framework delivers its delegate calls there too.
import AppKit
import ImageCaptureCore

final class MediaItem: ObservableObject, Identifiable, Hashable {
    enum Status: Equatable {
        case pending, copying, verified, alreadyCopied, deleted
        case failed(String)
        var isCopied: Bool { self == .verified || self == .alreadyCopied }
    }

    let file: ICCameraFile
    let id: String
    let name: String
    let size: Int
    let date: Date?
    let isVideo: Bool
    let isLivePhoto: Bool
    let duration: Double
    let pixelWidth: Int, pixelHeight: Int
    @Published var thumbnail: CGImage?
    @Published var status: Status = .pending

    init(_ file: ICCameraFile) {
        self.file = file
        name = file.name ?? "untitled"
        size = Int(file.fileSize)
        date = file.creationDate ?? file.modificationDate
        let ext = (name as NSString).pathExtension.lowercased()
        let uti = (file.uti ?? "").lowercased()
        isVideo = ["mov", "mp4", "m4v", "avi", "3gp"].contains(ext) || uti.contains("movie") || uti.contains("video")
        isLivePhoto = !isVideo && (file.sidecarFiles ?? []).contains { ($0.name ?? "").lowercased().hasSuffix(".mov") }
        duration = file.duration
        pixelWidth = file.width; pixelHeight = file.height
        id = "\(name)|\(size)|\(date?.timeIntervalSince1970 ?? 0)"
    }

    static func == (a: MediaItem, b: MediaItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct OffloadProgress {
    var done = 0, total = 0
    var bytesDone = 0, bytesTotal = 0
    var phase = ""
    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
}

struct OffloadOptions {
    var destination: URL
    var byDate: Bool
    var skipExisting: Bool
    var deleteAfterCopy: Bool
}

struct DeviceInfo {
    var manufacturer = "", model = "", version = "", serial = ""
    var modelNumber = "", region = "", udid = "", hardware = "", ecid = "", basebandSerial = "", basebandCert = ""
    var marketingName: String { DeviceInfo.names[model] ?? model }
    static let names: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e", "iPhone18,3": "iPhone 17",
    ]
}

struct DeviceStorage { var capacity: Int; var free: Int; var photos: Int? = nil; var apps: Int? = nil }

/// What the connected model looks like from the front, derived from its identifier (iPhone16,2 ...).
struct PhoneStyle {
    enum Cutout { case none, notch, island }
    var cutout: Cutout = .island
    var homeButton = false
    var fold = false                 // Duo: opens into a wider panel with a centre crease
    var width: CGFloat = 150, height: CGFloat = 312
    var corner: CGFloat = 30, bezel: CGFloat = 6

    static func style(for identifier: String?, name: String?) -> PhoneStyle {
        var s = PhoneStyle()
        guard let id = identifier, id.hasPrefix("iPhone"),
              let comma = id.firstIndex(of: ","),
              let major = Int(id.dropFirst(6)[..<comma]), let minor = Int(id[id.index(after: comma)...]) else {
            if (name ?? "").localizedCaseInsensitiveContains("Duo") { s.fold = true }
            return s
        }
        if (name ?? "").localizedCaseInsensitiveContains("Duo") { s.fold = true; return s }
        // Home-button era: 6/6s/7/8 and the SE line.
        let homeButton = major <= 9 || [(10, 1), (10, 2), (10, 4), (10, 5), (12, 8), (14, 6)].contains { $0 == (major, minor) }
        // Notch era: X/XS/XR through 14 and 14 Plus, plus the 16e.
        let notch = !homeButton && (major <= 13 || [(14, 2), (14, 3), (14, 4), (14, 5), (14, 7), (14, 8), (17, 5)].contains { $0 == (major, minor) })
        s.homeButton = homeButton
        s.cutout = homeButton ? .none : (notch ? .notch : .island)
        // Size class: Plus/Max/XR/XS Max bodies are bigger, minis smaller.
        let big = [(10, 2), (10, 5), (10, 6), (11, 4), (11, 6), (12, 5), (13, 4), (14, 3), (14, 8), (15, 3), (15, 5), (16, 2), (17, 2), (17, 4), (18, 2)].contains { $0 == (major, minor) }
        let mini = [(13, 1), (14, 4)].contains { $0 == (major, minor) }
        if homeButton { s.width = 148; s.height = 296; s.corner = 22; s.bezel = 7 }
        if big { s.width = 158; s.height = 328 }
        if mini { s.width = 140; s.height = 292 }
        return s
    }
}

struct BatteryInfo {
    var level: Int?, charging: Bool?
    var cycleCount: Int?, designCapacity: Int?, maxCapacity: Int?
    var health: Double? {
        guard let d = designCapacity, let m = maxCapacity, d > 0 else { return nil }
        return Double(m) / Double(d) * 100
    }
}

/// libimobiledevice (Homebrew) speaks Apple's lockdown service: the same details 3uTools shows.
enum Lockdown {
    static let available = tool("ideviceinfo") != nil

    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin"].map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ name: String, _ args: [String]) -> Data? {
        guard let path = tool(name) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    static func plist(_ name: String, _ args: [String]) -> [String: Any]? {
        guard let d = run(name, args), !d.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    static func firstUDID() -> String? {
        run("idevice_id", ["-l"]).flatMap { String(data: $0, encoding: .utf8) }?
            .split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

final class DeviceManager: NSObject, ObservableObject {
    @Published var info: DeviceInfo?
    @Published var storage: DeviceStorage?
    @Published var battery: BatteryInfo?
    @Published var device: ICCameraDevice?
    @Published var items: [MediaItem] = []
    @Published var selection: Set<String> = []
    @Published var catalogComplete = false
    @Published var locked = false
    @Published var sessionOpen = false
    @Published var canDelete = true           // false when the phone withholds delete (iCloud Photos on)
    @Published var connectAttempts = 0        // watchdog retries of a session open that never completed
    private var removedByPhone = Set<ObjectIdentifier>()
    @Published var running = false
    @Published var progress = OffloadProgress()
    @Published var summary: String?
    @Published var log: [String] = []
    private var cancelled = false

    func cancel() { cancelled = true }

    private let browser = ICDeviceBrowser()
    private var liveTimer: Timer?
    private var byFile: [ObjectIdentifier: MediaItem] = [:]
    private var pendingAdds: [MediaItem] = []
    private var flushScheduled = false

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        addLog("Waiting for an iPhone over USB…")
    }

    // MARK: Device

    /// Short form for table cells; `statusText` is the sentence for captions.
    var statusWord: String {
        guard device != nil else { return "–" }
        if locked { return "Locked" }
        if !sessionOpen { return "Connecting" }
        return catalogComplete ? "Ready" : "Reading library"
    }

    var statusText: String {
        guard device != nil else { return "No iPhone connected" }
        if locked { return "Locked: unlock and tap Trust" }
        if !sessionOpen { return "Connecting…" }
        if !catalogComplete { return "Reading library… \(items.count) items" }
        return "Ready"
    }

    func connect(_ camera: ICCameraDevice) {
        disconnect()
        device = camera
        camera.delegate = self
        locked = camera.isAccessRestrictedAppleDevice
        addLog("Found \(camera.name ?? "iPhone")")
        if Lockdown.available {
            queryLockdown()
            liveTimer?.invalidate()
            liveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshLive() }
        }
        connectAttempts = 0
        openSession(camera)
    }

    /// Ask for the session and keep a watchdog on it: a previous instance that quit mid-session can leave the
    /// camera service hanging, in which case the open never completes and never errors either.
    private func openSession(_ camera: ICCameraDevice) {
        camera.requestOpenSession()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.device === camera, !self.sessionOpen, !self.locked else { return }
            guard self.connectAttempts < 3 else {
                self.addLog("The iPhone's camera connection is not answering; unplug and replug the cable")
                return
            }
            self.connectAttempts += 1
            self.addLog("Connection is taking too long, retrying (\(self.connectAttempts) of 3)")
            if camera.hasOpenSession { camera.requestCloseSession() }
            self.openSession(camera)
        }
    }

    /// The Retry button: start the connection over.
    func retryConnection() {
        guard let d = device else { return }
        connectAttempts = 0
        if d.hasOpenSession { d.requestCloseSession() }
        openSession(d)
    }

    func disconnect() {
        liveTimer?.invalidate(); liveTimer = nil
        if let d = device, d.hasOpenSession { d.requestCloseSession() }
        device = nil
        info = nil; storage = nil; battery = nil
        items = []; byFile = [:]; pendingAdds = []
        selection = []
        catalogComplete = false; sessionOpen = false; locked = false
    }

    func refresh() {
        guard let d = device else { return }
        items = []; byFile = [:]; selection = []; catalogComplete = false
        if d.hasOpenSession { d.requestCloseSession() }
        connectAttempts = 0
        openSession(d)
    }

    private func flushAdds() {
        flushScheduled = false
        guard !pendingAdds.isEmpty else { return }
        items.append(contentsOf: pendingAdds)
        pendingAdds = []
    }

    /// Newest photos shown on the rendered phone's screen.
    var screenItems: [MediaItem] {
        Array(items.filter { !$0.isVideo }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(12))
    }

    // MARK: Preview

    private var previewCache: [String: URL] = [:]
    private static let previewDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("Decant/preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// The item at full size, downloaded from the phone the first time it is viewed.
    func previewURL(for item: MediaItem) async -> URL? {
        if let u = previewCache[item.id], FileManager.default.fileExists(atPath: u.path) { return u }
        let url = Self.previewDir.appendingPathComponent(item.name)
        if case .success = await download(item.file, to: Self.previewDir, sidecars: false), FileManager.default.fileExists(atPath: url.path) {
            previewCache[item.id] = url
            return url
        }
        return nil
    }

    // MARK: Totals

    var photoCount: Int { items.filter { !$0.isVideo }.count }
    var videoCount: Int { items.filter { $0.isVideo }.count }
    var liveCount: Int { items.filter { $0.isLivePhoto }.count }
    var totalBytes: Int { items.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int { items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func addLog(_ line: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(t)  \(line)")
        NSLog("%@", line)                       // mirrored to the system log for diagnosis
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    // MARK: Offload

    func offload(_ opts: OffloadOptions, only: [MediaItem]? = nil) {
        guard let camera = device, !running else { return }
        let targets = only ?? items.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        running = true; cancelled = false; summary = nil
        progress = OffloadProgress(done: 0, total: targets.count, bytesDone: 0,
                                   bytesTotal: targets.reduce(0) { $0 + $1.size }, phase: "Copying")
        addLog("Offloading \(targets.count) items (\(Self.gb(progress.bytesTotal))) to \(opts.destination.path)")
        Task { @MainActor in
            let fm = FileManager.default
            var copied = 0, skipped = 0, failed = 0
            for item in targets {
                if cancelled { addLog("Stopped by user"); break }
                let dir = opts.byDate ? Self.dateFolder(opts.destination, item.date) : opts.destination
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appendingPathComponent(item.name)
                if opts.skipExisting, Self.size(of: target) == item.size {
                    item.status = .alreadyCopied; skipped += 1
                } else {
                    item.status = .copying
                    switch await download(item.file, to: dir) {
                    case .failure(let error):
                        item.status = .failed(error.localizedDescription); failed += 1
                        addLog("FAILED \(item.name): \(error.localizedDescription)")
                    case .success:
                        if Self.size(of: target) == item.size {
                            Self.stampDates(target, item.date)
                            item.status = .verified; copied += 1
                        } else {
                            item.status = .failed("size mismatch after copy"); failed += 1
                            addLog("FAILED \(item.name): size on disk does not match the phone")
                        }
                    }
                }
                progress.done += 1
                progress.bytesDone += item.size
            }
            addLog("Copy finished: \(copied) copied, \(skipped) already there, \(failed) failed")
            var deleted = 0
            if opts.deleteAfterCopy && !cancelled && copied + skipped > 0 {
                progress.phase = "Deleting"
                deleted = await deleteAnyWay(camera, targets.filter { $0.status.isCopied })
            }
            progress.phase = "Done"
            var parts = ["\(copied + skipped) of \(targets.count) items on the Mac"]
            if skipped > 0 { parts.append("\(skipped) were already there") }
            if failed > 0 { parts.append("\(failed) failed") }
            if deleted > 0 { parts.append("\(deleted) deleted from the iPhone") }
            if cancelled { parts.insert("Stopped", at: 0) }
            summary = parts.joined(separator: " · ")
            running = false
        }
    }

    private func download(_ file: ICCameraFile, to dir: URL, sidecars: Bool = true) async -> Result<Void, Error> {
        await withCheckedContinuation { cont in
            file.requestDownload(options: [.downloadsDirectoryURL: dir, .overwrite: true, .sidecarFiles: sidecars]) { _, error in
                DispatchQueue.main.async {
                    if let error { cont.resume(returning: .failure(error)) } else { cont.resume(returning: .success(())) }
                }
            }
        }
    }

    // Only files whose copy was verified are deleted. The phone may keep them in Recently Deleted for 30 days.
    @discardableResult
    private func deleteCopied(_ camera: ICCameraDevice, _ targets: [MediaItem]) async -> Int {
        let toDelete = targets.filter { $0.status.isCopied }
        guard !toDelete.isEmpty else { return 0 }
        addLog("Deleting \(toDelete.count) verified items from the iPhone…")
        return await deleteFromPhone(camera, toDelete)
    }

    /// Delete items on the phone outright (context menu). Nothing is copied first; the caller has confirmed.
    func deleteFromPhone(_ items: [MediaItem]) {
        guard let camera = device, !running else { return }
        running = true
        Task { @MainActor in
            let n = await deleteAnyWay(camera, items)
            summary = "\(n) of \(items.count) deleted"
            running = false
        }
    }

    /// USB first (instant, no dialog) when the phone claims to allow it; whatever it does not confirm goes
    /// through iCloud. With iCloud Photos on, iOS advertises the capability and then silently ignores the delete.
    private func deleteAnyWay(_ camera: ICCameraDevice, _ items: [MediaItem]) async -> Int {
        var done = 0
        var remaining = items
        if canDelete {
            done = await deleteFromPhone(camera, items)
            remaining = items.filter { $0.status != .deleted }
            if !remaining.isEmpty { addLog("\(remaining.count) items were not removed over USB; deleting them through iCloud instead") }
        }
        if !remaining.isEmpty { done += await deleteViaICloud(remaining) }
        return done
    }

    /// iCloud route: delete the same assets from the Mac's Photos library; iCloud removes them from the phone.
    private func deleteViaICloud(_ items: [MediaItem]) async -> Int {
        addLog("Deleting \(items.count) items through iCloud (Photos library on this Mac)…")
        progress.phase = "Matching in Photos library"
        do {
            let (deleted, missing) = try await PhotoLibraryDeleter.delete(items)
            for i in deleted { i.status = .deleted }
            removeFromList(deleted)
            for i in missing { i.status = .failed("not found in the Mac's Photos library") }
            if !missing.isEmpty { addLog("\(missing.count) items were not in the Mac's Photos library yet (iCloud still syncing?)") }
            addLog("Deleted \(deleted.count) through iCloud; the iPhone drops them when it syncs (Recently Deleted keeps them 30 days)")
            scheduleRescan()
            return deleted.count
        } catch {
            addLog("iCloud delete failed: \(error.localizedDescription)")
            for i in items { i.status = .failed(error.localizedDescription) }
            return 0
        }
    }

    /// After an iCloud delete the phone catches up on its own schedule: re-read it twice so the library shown
    /// is the phone's, not our bookkeeping.
    private func scheduleRescan() {
        Task { @MainActor [weak self] in
            for delay in [20, 60] {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard let self, self.device != nil, !self.running else { return }
                self.addLog("Re-reading the iPhone after the iCloud delete")
                self.refresh()
            }
        }
    }

    /// Items the user deleted leave the grid now; the phone's own removal notice later finds nothing to do.
    private func removeFromList(_ gone: [MediaItem]) {
        let ids = Set(gone.map { $0.id })
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        for g in gone { byFile[ObjectIdentifier(g.file)] = nil }
    }

    private func deleteFromPhone(_ camera: ICCameraDevice, _ toDelete: [MediaItem]) async -> Int {
        var deleted = 0
        for start in stride(from: 0, to: toDelete.count, by: 50) {
            let chunk = Array(toDelete[start..<min(start + 50, toDelete.count)])
            let failedItems: Set<ObjectIdentifier> = await withCheckedContinuation { cont in
                var failedSet = Set<ObjectIdentifier>()
                camera.requestDeleteFiles(chunk.map { $0.file }, deleteFailed: { failures in
                    for (_, item) in failures { failedSet.insert(ObjectIdentifier(item)) }
                }, completion: { _, error in
                    DispatchQueue.main.async {
                        if let error { self.addLog("Delete error: \(error.localizedDescription)") }
                        cont.resume(returning: failedSet)
                    }
                })
            }
            // The phone announces removals itself; wait briefly for that rather than trusting the completion.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for item in chunk {
                if failedItems.contains(ObjectIdentifier(item.file)) {
                    item.status = .failed("phone refused to delete")
                } else if removedByPhone.contains(ObjectIdentifier(item.file)) || item.status == .deleted {
                    item.status = .deleted; deleted += 1
                } else {
                    item.status = .failed("phone did not confirm the delete")
                }
            }
        }
        addLog("Deleted \(deleted) of \(toDelete.count) from the iPhone" + (deleted < toDelete.count ? " (check Recently Deleted and the iCloud Photos setting)" : ""))
        removeFromList(toDelete.filter { $0.status == .deleted })
        return deleted
    }

    // MARK: Raw PTP (device details)

    private func ptp(_ camera: ICCameraDevice, code: UInt16, params: [UInt32] = []) async -> Data? {
        var cmd = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { cmd.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { cmd.append(contentsOf: $0) } }
        put32(UInt32(12 + 4 * params.count)); put16(1); put16(code); put32(1)
        params.forEach(put32)
        return await withCheckedContinuation { cont in
            camera.requestSendPTPCommand(cmd, outData: nil) { response, data, error in
                DispatchQueue.main.async {
                    guard error == nil, response.count >= 8,
                          response.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }) == 0x2001 else {
                        cont.resume(returning: nil); return
                    }
                    var d = data
                    // Some stacks hand back the data container (12-byte header) rather than the bare dataset.
                    if d.count >= 12, d.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == UInt32(d.count),
                       d.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }) == 2 {
                        d = d.subdata(in: 12..<d.count)
                    }
                    cont.resume(returning: d)
                }
            }
        }
    }

    private struct PTPReader {
        let d: Data; var i = 0
        init(_ d: Data) { self.d = d }
        mutating func u16() -> UInt16 { defer { i += 2 }; return i + 2 <= d.count ? d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt16.self) } : 0 }
        mutating func u32() -> UInt32 { defer { i += 4 }; return i + 4 <= d.count ? d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self) } : 0 }
        mutating func u64() -> UInt64 { defer { i += 8 }; return i + 8 <= d.count ? d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt64.self) } : 0 }
        mutating func string() -> String {   // u8 char count (incl. terminator), UCS-2 chars
            guard i < d.count else { return "" }
            let n = Int(d[i]); i += 1
            var units: [UInt16] = []
            for _ in 0..<n { units.append(u16()) }
            return String(utf16CodeUnits: units, count: units.count).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        mutating func skipArray16() { let n = Int(u32()); i += 2 * n }
    }

    private func queryDetails(_ camera: ICCameraDevice) {
        guard info == nil else { return }
        if Lockdown.available { queryLockdown(); return }
        Task { @MainActor in
            if let d = await ptp(camera, code: 0x1001) {          // GetDeviceInfo
                var r = PTPReader(d)
                _ = r.u16(); _ = r.u32(); _ = r.u16(); _ = r.string(); _ = r.u16()
                r.skipArray16(); r.skipArray16(); r.skipArray16(); r.skipArray16(); r.skipArray16()
                var inf = DeviceInfo()
                inf.manufacturer = r.string(); inf.model = r.string(); inf.version = r.string(); inf.serial = r.string()
                if !inf.model.isEmpty { info = inf; addLog("\(inf.marketingName) (\(inf.model)), iOS \(inf.version)") }
            }
            if let ids = await ptp(camera, code: 0x1004) {        // GetStorageIDs
                var r = PTPReader(ids)
                let n = Int(r.u32())
                if n > 0, let s = await ptp(camera, code: 0x1005, params: [r.u32()]) {   // GetStorageInfo
                    var sr = PTPReader(s)
                    _ = sr.u16(); _ = sr.u16(); _ = sr.u16()
                    let cap = Int(sr.u64()), free = Int(sr.u64())
                    if cap > 0 { storage = DeviceStorage(capacity: cap, free: free) }
                }
            }
        }
    }

    // MARK: Device tools (lockdown one-liners)

    func restart() { deviceCommand("idevicediagnostics", ["restart"], "Restarting the iPhone") }
    func shutDown() { deviceCommand("idevicediagnostics", ["shutdown"], "Shutting the iPhone down") }
    func rename(_ name: String) { deviceCommand("idevicename", [name], "Renaming the iPhone to \(name)") }

    private func deviceCommand(_ tool: String, _ args: [String], _ what: String) {
        addLog(what)
        Task.detached { () -> Void in
            var a: [String] = []
            if let udid = Lockdown.firstUDID() { a = ["-u", udid] }
            let ok = Lockdown.run(tool, a + args) != nil
            await MainActor.run { self.addLog(ok ? "\(what): done" : "\(what): failed (is the iPhone unlocked and trusted?)") }
        }
    }

    // MARK: Lockdown (libimobiledevice)

    /// Battery and storage only: cheap, and they change while the phone sits on the cable.
    func refreshLive() {
        guard device != nil, Lockdown.available else { return }
        Task.detached(priority: .utility) { [weak self] () -> Void in
            var args: [String] = []
            if let udid = Lockdown.firstUDID() { args = ["-u", udid] }
            let batt = Lockdown.plist("ideviceinfo", args + ["-x", "-q", "com.apple.mobile.battery"])
            let disk = Lockdown.plist("ideviceinfo", args + ["-x", "-q", "com.apple.disk_usage"])
            let diag = Lockdown.plist("idevicediagnostics", args + ["ioregentry", "AppleSmartBattery"])
            await MainActor.run {
                guard let self else { return }
                self.applyBattery(batt, diag)
                self.applyDisk(disk)
            }
        }
    }

    private func applyBattery(_ batt: [String: Any]?, _ diag: [String: Any]?) {
        func find(_ key: String, in any: Any?) -> Int? {
            guard let dict = any as? [String: Any] else { return nil }
            if let v = dict[key] as? Int { return v }
            for v in dict.values { if let r = find(key, in: v) { return r } }
            return nil
        }
        var b = BatteryInfo()
        b.level = batt?["BatteryCurrentCapacity"] as? Int
        b.charging = batt?["BatteryIsCharging"] as? Bool
        b.cycleCount = find("CycleCount", in: diag)
        b.designCapacity = find("DesignCapacity", in: diag)
        b.maxCapacity = find("NominalChargeCapacity", in: diag) ?? find("AppleRawMaxCapacity", in: diag)
        if b.level != nil || b.cycleCount != nil { battery = b }
    }

    private func applyDisk(_ d: [String: Any]?) {
        if let d, let cap = d["TotalDiskCapacity"] as? Int, let free = d["TotalDataAvailable"] as? Int {
            storage = DeviceStorage(capacity: cap, free: free,
                                    photos: d["CameraUsage"] as? Int ?? d["PhotoUsage"] as? Int,
                                    apps: d["MobileApplicationUsage"] as? Int)
        }
    }

    private func queryLockdown() {
        Task.detached(priority: .userInitiated) { [weak self] () -> Void in
            var args: [String] = []
            if let udid = Lockdown.firstUDID() { args = ["-u", udid] }
            let general = Lockdown.plist("ideviceinfo", args + ["-x"])
            let batt = Lockdown.plist("ideviceinfo", args + ["-x", "-q", "com.apple.mobile.battery"])
            let disk = Lockdown.plist("ideviceinfo", args + ["-x", "-q", "com.apple.disk_usage"])
            let diag = Lockdown.plist("idevicediagnostics", args + ["ioregentry", "AppleSmartBattery"])
            await MainActor.run {
                guard let self else { return }
                if let g = general {
                    var inf = DeviceInfo()
                    inf.manufacturer = "Apple"
                    inf.model = g["ProductType"] as? String ?? ""
                    inf.version = g["ProductVersion"] as? String ?? ""
                    inf.serial = g["SerialNumber"] as? String ?? ""
                    inf.modelNumber = g["ModelNumber"] as? String ?? ""
                    inf.region = g["RegionInfo"] as? String ?? ""
                    inf.udid = g["UniqueDeviceID"] as? String ?? ""
                    inf.hardware = g["HardwareModel"] as? String ?? ""
                    if let e = g["UniqueChipID"] as? Int { inf.ecid = String(e) }
                    if let bb = g["BasebandSerialNumber"] as? Data { inf.basebandSerial = bb.map { String(format: "%02x", $0) }.joined() }
                    if let c = g["BasebandGoldCertId"] as? Int { inf.basebandCert = String(c) }
                    if !inf.model.isEmpty {
                        self.info = inf
                        self.addLog("\(inf.marketingName) (\(inf.model)), iOS \(inf.version)")
                    }
                } else {
                    self.addLog("Could not read device details (is the iPhone paired with this Mac?)")
                }
                self.applyBattery(batt, diag)
                self.applyDisk(disk)
            }
        }
    }

    // MARK: Helpers

    static func gb(_ bytes: Int) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// Original capture date on the copy, and world-readable so a photo server (Immich, Plex) can read it.
    static func stampDates(_ url: URL, _ date: Date?) {
        var attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        if let date { attrs[.creationDate] = date; attrs[.modificationDate] = date }
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        // Sidecars (Live Photo movies, edits) arrive next to the file with the same stem.
        let stem = url.deletingPathExtension().lastPathComponent
        for f in (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            where f.deletingPathExtension().lastPathComponent == stem && f != url {
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: f.path)
        }
    }

    private static let yearFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy"; return f }()
    private static let monthFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f }()

    static func dateFolder(_ root: URL, _ date: Date?) -> URL {
        guard let date else { return root.appendingPathComponent("Undated") }
        return root.appendingPathComponent(yearFmt.string(from: date)).appendingPathComponent(monthFmt.string(from: date))
    }

    static func freeSpace(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
    }
}

// MARK: - Image Capture delegates

extension DeviceManager: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        if self.device == nil { connect(camera) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === self.device {
            addLog("\(device.name ?? "iPhone") unplugged")
            disconnect()
        }
    }
}

extension DeviceManager: ICCameraDeviceDelegate {
    func didRemove(_ device: ICDevice) {
        if device === self.device { disconnect() }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            addLog("Could not open the iPhone: \(error.localizedDescription)")
            // Locked or not yet trusted: keep trying until the phone lets us in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let d = self.device, d === device, !self.sessionOpen else { return }
                self.openSession(d)
            }
            return
        }
        sessionOpen = true
        if let c = device as? ICCameraDevice {
            locked = c.isAccessRestrictedAppleDevice
            canDelete = c.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
            addLog(canDelete ? "Phone allows deleting over USB" : "Phone does not allow deleting over USB (iCloud Photos is on)")
            queryDetails(c)
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        sessionOpen = false
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        for case let file as ICCameraFile in items {
            let key = ObjectIdentifier(file)
            guard byFile[key] == nil else { continue }
            let item = MediaItem(file)
            byFile[key] = item
            pendingAdds.append(item)
        }
        if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.flushAdds() }
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        let gone = Set(items.map { ObjectIdentifier($0) })
        removedByPhone.formUnion(gone)
        for k in gone { byFile[k]?.status = .deleted }
        self.selection.subtract(self.items.filter { gone.contains(ObjectIdentifier($0.file)) }.map { $0.id })
        self.items.removeAll { gone.contains(ObjectIdentifier($0.file)) }
        for k in gone { byFile[k] = nil }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        byFile[ObjectIdentifier(item)]?.thumbnail = thumbnail
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        flushAdds()
        if info == nil { queryDetails(device) }
        catalogComplete = true
        selection = []                      // nothing selected until the user chooses
        screenItems.forEach { if $0.thumbnail == nil { $0.file.requestThumbnail() } }
        addLog("Library read: \(photoCount) photos, \(videoCount) videos (\(liveCount) Live Photos), \(Self.gb(totalBytes))")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        locked = true
        addLog("iPhone is locked: unlock it and tap Trust")
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        locked = false
        addLog("iPhone unlocked")
        if let d = self.device {
            if d.hasOpenSession { queryDetails(d) } else { d.requestOpenSession() }
        }
    }
}
