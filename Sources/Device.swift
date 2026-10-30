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
    var modelNumber = "", region = "", udid = "", hardware = ""
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
    @Published var running = false
    @Published var progress = OffloadProgress()
    @Published var summary: String?
    @Published var log: [String] = []
    private var cancelled = false

    func cancel() { cancelled = true }

    private let browser = ICDeviceBrowser()
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
        camera.requestOpenSession()
    }

    func disconnect() {
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
        d.requestOpenSession()
    }

    private func flushAdds() {
        flushScheduled = false
        guard !pendingAdds.isEmpty else { return }
        items.append(contentsOf: pendingAdds)
        pendingAdds = []
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
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    // MARK: Offload

    func offload(_ opts: OffloadOptions) {
        guard let camera = device, !running else { return }
        let targets = items.filter { selection.contains($0.id) }
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
                progress.phase = "Deleting from iPhone"
                deleted = await deleteCopied(camera, targets)
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

    private func download(_ file: ICCameraFile, to dir: URL) async -> Result<Void, Error> {
        await withCheckedContinuation { cont in
            file.requestDownload(options: [.downloadsDirectoryURL: dir, .overwrite: true, .sidecarFiles: true]) { _, error in
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
            for item in chunk {
                if failedItems.contains(ObjectIdentifier(item.file)) {
                    item.status = .failed("phone refused to delete")
                } else {
                    item.status = .deleted; deleted += 1
                }
            }
        }
        addLog("Deleted \(deleted) of \(toDelete.count) from the iPhone")
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

    // MARK: Lockdown (libimobiledevice)

    private func queryLockdown() {
        Task.detached(priority: .userInitiated) { [weak self] in
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
                    if !inf.model.isEmpty {
                        self.info = inf
                        self.addLog("\(inf.marketingName) (\(inf.model)), iOS \(inf.version)")
                    }
                } else {
                    self.addLog("Could not read device details (is the iPhone paired with this Mac?)")
                }
                var b = BatteryInfo()
                b.level = batt?["BatteryCurrentCapacity"] as? Int
                b.charging = batt?["BatteryIsCharging"] as? Bool
                let entry = (diag?["IORegistry"] as? [String: Any]) ?? diag ?? [:]
                b.cycleCount = entry["CycleCount"] as? Int
                b.designCapacity = entry["DesignCapacity"] as? Int
                b.maxCapacity = (entry["NominalChargeCapacity"] as? Int) ?? (entry["AppleRawMaxCapacity"] as? Int)
                if b.level != nil || b.cycleCount != nil { self.battery = b }
                if let d = disk, let cap = d["TotalDiskCapacity"] as? Int, let free = d["TotalDataAvailable"] as? Int {
                    self.storage = DeviceStorage(capacity: cap, free: free,
                                                 photos: d["CameraUsage"] as? Int ?? d["PhotoUsage"] as? Int,
                                                 apps: d["MobileApplicationUsage"] as? Int)
                }
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

    static func stampDates(_ url: URL, _ date: Date?) {
        guard let date else { return }
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
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
                d.requestOpenSession()
            }
            return
        }
        sessionOpen = true
        if let c = device as? ICCameraDevice {
            locked = c.isAccessRestrictedAppleDevice
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
        selection = Set(items.map { $0.id })
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
