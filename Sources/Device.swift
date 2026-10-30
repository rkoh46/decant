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

final class DeviceManager: NSObject, ObservableObject {
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
        if locked { return "Unlock the iPhone and tap Trust" }
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

    // MARK: Helpers

    static func gb(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
        if let c = device as? ICCameraDevice { locked = c.isAccessRestrictedAppleDevice }
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
        if let d = self.device, !d.hasOpenSession { d.requestOpenSession() }
    }
}
