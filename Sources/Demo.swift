// Sample data for screenshots and demos: `DECANT_DEMO=1 Decant` shows a complete iPhone that does not exist,
// so the app can be photographed without anyone's photos, contacts or serial numbers on screen. Photos come from
// the Mac's own wallpapers, app icons from the Mac's own Apple apps. Nothing here runs unless the variable is set.
import AppKit
import ImageCaptureCore

/// A camera device object the Image Capture framework never created; only the name is ever read from it.
final class DemoCamera: ICCameraDevice {
    override var name: String? { Demo.deviceName }
    override var productKind: String? { "iPhone" }
    override var hasOpenSession: Bool { true }
}

enum Demo {
    static let on = ProcessInfo.processInfo.environment["DECANT_DEMO"] == "1"
    static let deviceName = "Sam's iPhone"
    static let udid = "00008140-000A1C2E3F4G5H6I"
    static let ecid = "1234567890123456"

    private static let day: TimeInterval = 86400
    private static func daysAgo(_ n: Double) -> Date { Date(timeIntervalSinceNow: -n * day) }

    // MARK: Device

    static func info() -> DeviceInfo {
        var i = DeviceInfo()
        i.manufacturer = "Apple"; i.model = "iPhone17,2"; i.version = "26.1"; i.serial = "F2LXK9Q1P7M3"
        i.modelNumber = "MYWX3"; i.region = "LL/A"; i.udid = udid; i.hardware = "D94AP"; i.ecid = ecid
        i.imei = "356728113457890"; i.imei2 = "356728113457908"; i.meid = "35672811345789"
        i.wifiAddress = "a4:83:e7:2b:91:0c"; i.bluetoothAddress = "a4:83:e7:2b:91:0d"
        i.basebandSerial = "4f1c0a9b"; i.basebandCert = "3095460737"
        return i
    }

    static func storage() -> DeviceStorage {
        let gb = 1_000_000_000
        return DeviceStorage(capacity: 512 * gb, free: 182 * gb, photos: 96 * gb, apps: 118 * gb, system: 14 * gb, reserved: 6 * gb,
                             music: 19 * gb, messages: 8 * gb, mail: 2 * gb)
    }

    static func battery() -> BatteryInfo {
        var b = BatteryInfo()
        b.level = 78; b.charging = true; b.cycleCount = 412; b.designCapacity = 4685; b.maxCapacity = 4387
        b.temperature = 29.4; b.voltage = 4.21; b.amperage = 2.9; b.adapterWatts = 20; b.adapterName = "USB-C PD"; b.externalConnected = true
        return b
    }

    static func batteryHistory() -> [BatterySample] {
        (0..<60).reversed().map { week in
            let t = Double(60 - week) / 60
            return BatterySample(date: daysAgo(Double(week) * 7), level: [100, 82, 64, 91, 47, 73][week % 6], charging: week % 3 == 0,
                                 cycleCount: Int(412 * t), maxCapacity: 4685 - Int(298 * t), designCapacity: 4685,
                                 temperature: 27 + Double(week % 5), voltage: 3.9 + Double(week % 4) * 0.1)
        }
    }

    static func diagnostics() -> [String: Any] {
        ["GasGauge": ["CycleCount": 412, "DesignCapacity": 4685, "FullChargeCapacity": 4387, "Status": "Success"],
         "NAND": ["Status": "Success"],
         "WiFi": ["Active": "YES", "Status": "Success"],
         "HDMI": ["Connection": "No", "Status": "Success"],
         "Status": "Success"]
    }

    // MARK: Photos, from the Mac's wallpapers

    static func mediaItems() -> [MediaItem] {
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["heic", "jpg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !all.isEmpty else { return [] }
        // The one landscape photograph among the wallpapers (Sonoma) gives a trip's worth of crops; the rest fill in.
        let photos = all.filter { ["Sonoma", "Sequoia", "Tahoe", "Ventura", "Monterey", "Big Sur"].contains(where: $0.lastPathComponent.hasPrefix) }
        let others = all.filter { !photos.contains($0) }
        var items: [MediaItem] = []
        var seed: UInt64 = 7
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for n in 0..<120 {
            let usePhoto = !photos.isEmpty && (others.isEmpty || n % 3 != 2)
            let src = usePhoto ? photos[n % photos.count] : others[n % max(others.count, 1)]
            let age = Double(n) * 21 + Double(rnd(20))
            let video = n % 9 == 4
            let name = String(format: video ? "IMG_%04d.MOV" : "IMG_%04d.HEIC", 4821 - n)
            let size = video ? 48_000_000 + rnd(200_000_000) : 1_800_000 + rnd(4_000_000)
            items.append(MediaItem(sample: name, size: size, date: daysAgo(age), isVideo: video, isLivePhoto: !video && n % 4 == 1,
                                   duration: video ? Double(8 + rnd(90)) : 0, pixelWidth: video ? 3840 : 4032, pixelHeight: video ? 2160 : 3024,
                                   thumbnail: thumbnail(src, crop: usePhoto ? n : nil)))
        }
        return items
    }

    private static var thumbCache: [String: CGImage] = [:]

    /// A 320 px thumbnail; with `crop`, one of nine square windows into the image so one photograph reads as many.
    private static func thumbnail(_ url: URL, crop: Int?) -> CGImage? {
        let key = "\(url.path)|\(crop.map { $0 % 9 } ?? -1)"
        if let c = thumbCache[key] { return c }
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: crop == nil ? 320 : 1200,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard var img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { return nil }
        if let crop {
            let side = min(img.width, img.height) * 42 / 100
            let i = crop % 9
            let x = (img.width - side) * (i % 3) / 2, y = (img.height - side) * (i / 3) / 2
            if let c = img.cropping(to: CGRect(x: x, y: y, width: side, height: side)) { img = c }
        }
        thumbCache[key] = img
        return img
    }

    // MARK: Apps, from the Mac's Apple apps

    private static let appTable: [(String, String, Int, Int, Bool)] = [   // bundle, Mac app name, app MB, data MB, file sharing
        ("com.apple.mobilesafari", "Safari", 410, 2900, false), ("com.apple.MobileSMS", "Messages", 120, 8200, false),
        ("com.apple.mobilemail", "Mail", 140, 2100, false), ("com.apple.Maps", "Maps", 380, 640, false),
        ("com.apple.Music", "Music", 290, 19400, false), ("com.apple.mobilenotes", "Notes", 150, 1300, false),
        ("com.apple.podcasts", "Podcasts", 180, 4400, false), ("com.apple.reminders", "Reminders", 60, 12, false),
        ("com.apple.stocks", "Stocks", 40, 8, false), ("com.apple.tv", "TV", 210, 3100, false),
        ("com.apple.weather", "Weather", 70, 24, false), ("com.apple.iBooks", "Books", 160, 2600, true),
        ("com.apple.mobilecal", "Calendar", 50, 30, false), ("com.apple.MobileAddressBook", "Contacts", 30, 18, false),
        ("com.apple.facetime", "FaceTime", 40, 6, false), ("com.apple.freeform", "Freeform", 120, 410, false),
        ("com.apple.Home", "Home", 90, 44, false), ("com.apple.news", "News", 130, 980, false),
        ("com.apple.shortcuts", "Shortcuts", 110, 60, false), ("com.apple.VoiceMemos", "Voice Memos", 30, 720, true),
        ("com.apple.findmy", "Find My", 60, 10, false), ("com.apple.calculator", "Calculator", 10, 1, false),
        ("com.apple.Keynote", "Keynote", 690, 1200, true), ("com.apple.Numbers", "Numbers", 540, 300, true),
        ("com.apple.Pages", "Pages", 580, 860, true), ("com.apple.garageband", "GarageBand", 1700, 2400, true),
        ("com.apple.iMovie", "iMovie", 720, 5100, true), ("com.apple.PhotoBooth", "Photo Booth", 90, 300, false),
    ]

    static func apps() -> [InstalledApp] {
        let have = icons()
        return appTable.enumerated().filter { have[$0.element.0] != nil }.map { i, a in
            var app = InstalledApp(bundleID: a.0, name: a.1, version: "\(18 + i % 9).\(i % 4)", staticSize: a.2 * 1_000_000, dynamicSize: a.3 * 1_000_000,
                                   fileSharing: a.4, system: false)
            app.developer = "Apple"
            app.purchased = daysAgo(Double(40 + i * 37))
            return app
        }
    }

    static func icons() -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for a in appTable {
            for root in ["/System/Applications", "/Applications", "/System/Applications/Utilities"] {
                let p = "\(root)/\(a.1).app"
                if FileManager.default.fileExists(atPath: p) { out[a.0] = NSWorkspace.shared.icon(forFile: p); break }
            }
        }
        return out
    }

    // MARK: Files

    static func files(root: FileRoot, path: String) -> [RemoteEntry] {
        func f(_ n: String, _ size: Int, _ age: Double) -> RemoteEntry { RemoteEntry(name: n, isDirectory: false, size: size, modified: daysAgo(age)) }
        func d(_ n: String, _ age: Double) -> RemoteEntry { RemoteEntry(name: n, isDirectory: true, size: 0, modified: daysAgo(age)) }
        switch root {
        case .media:
            switch path {
            case "/": return [d("Books", 40), d("DCIM", 1), d("Downloads", 3), d("iTunes_Control", 2), d("PhotoData", 1), d("Podcasts", 5),
                              d("Purchases", 30), d("Recordings", 12), d("Ringtones", 90)]
            case "/DCIM": return [d("100APPLE", 400), d("101APPLE", 200), d("102APPLE", 60), d("103APPLE", 1)]
            case "/Downloads": return [f("Flight itinerary.pdf", 184_000, 3), f("Receipt 2026-10-12.pdf", 92_000, 18), f("Lease.pdf", 1_240_000, 160)]
            case "/Recordings": return [f("20261019 143022.m4a", 4_200_000, 12), f("20260903 091500.m4a", 12_400_000, 58), f("CloudRecordings.db", 98_304, 12)]
            default: return []
            }
        case .appDocuments(_, let name):
            if name == "Books" { return [f("Dune.epub", 1_900_000, 40), f("Project Hail Mary.epub", 1_300_000, 120)] }
            return [d("Projects", 4), f("Untitled.key", 2_400_000, 4), f("Budget 2026.numbers", 310_000, 22)]
        case .ringtones: return []
        }
    }

    // MARK: Backups and firmware

    static func backups() -> [BackupInfo] {
        [BackupInfo(url: URL(fileURLWithPath: "/Users/sam/Documents/Decant/Backups/2026-10-28 2210/\(udid)"), date: daysAgo(2.2), size: 61_400_000_000,
                    deviceName: deviceName, version: "26.1", encrypted: true),
         BackupInfo(url: URL(fileURLWithPath: "/Users/sam/Documents/Decant/Backups/2026-09-30 0905/\(udid)"), date: daysAgo(30.6), size: 58_900_000_000,
                    deviceName: deviceName, version: "26.0.1", encrypted: true)]
    }

    static func finderBackups() -> [BackupInfo] {
        [BackupInfo(url: URL(fileURLWithPath: "/Users/sam/Library/Application Support/MobileSync/Backup/\(udid)"), date: daysAgo(74), size: 52_100_000_000,
                    deviceName: deviceName, version: "18.6.2", encrypted: false)]
    }

    static func summary() -> BackupSummary {
        var s = BackupSummary()
        s.messages = 48_212; s.conversations = 163; s.contacts = 412; s.calls = 2_874; s.notes = 231; s.voiceMemos = 38
        s.safariHistory = 19_440; s.whatsappChats = 57; s.whatsappMessages = 31_905
        return s
    }

    static func firmwares() -> [Firmware] {
        func fw(_ v: String, _ b: String, _ signed: Bool, _ date: String, _ gb: Double) -> Firmware {
            Firmware(version: v, buildid: b, url: URL(string: "https://updates.cdn-apple.com/iPhone17,2_\(v)_\(b)_Restore.ipsw")!, sha256: nil,
                     filesize: Int(gb * 1_000_000_000), signed: signed, releasedate: date)
        }
        return [fw("26.1", "23B85", true, "2026-11-03", 7.9), fw("26.0.1", "23A355", true, "2026-09-29", 7.8), fw("26.0", "23A341", false, "2026-09-15", 7.8),
                fw("18.6.2", "22G100", false, "2026-08-20", 7.1), fw("18.6", "22G86", false, "2026-07-29", 7.1), fw("18.5", "22F76", false, "2026-05-12", 7.0)]
    }

    static func blobs() -> [BlobInfo] {
        [("26.1", "23B85", 1.0), ("26.0.1", "23A355", 31.0), ("26.0", "23A341", 45.0), ("18.6.2", "22G100", 70.0)].map { v, b, age in
            BlobInfo(url: URL(fileURLWithPath: "/Users/sam/Documents/Decant/Blobs/\(ecid)/\(ecid)_iPhone17,2_D94AP_\(v)-\(b)_0x1111111111111111.shsh2"),
                     version: v, build: b, generator: "0x1111111111111111", date: daysAgo(age))
        }
    }

    static func ringtones() -> [Ringtone] {
        [Ringtone(file: "Morning Light.m4r", name: "Morning Light", duration: 30, pid: 1), Ringtone(file: "Bell Tower.m4r", name: "Bell Tower", duration: 24, pid: 2),
         Ringtone(file: "Front Desk.m4r", name: "Front Desk", duration: 30, pid: 3)]
    }

    // MARK: Wiring

    /// Puts the sample phone into the device manager as if it had just finished reading its library.
    static func fill(_ m: DeviceManager) {
        Lockdown.cachedUDID = udid
        m.device = DemoCamera()
        m.info = info(); m.storage = storage(); m.battery = battery(); m.batteryHistory = batteryHistory(); m.diagnostics = diagnostics()
        m.items = mediaItems()
        m.sessionOpen = true; m.catalogComplete = true; m.locked = false; m.canDelete = false
        m.networkUDIDs = [udid]
        m.addLog("Sample iPhone loaded (DECANT_DEMO=1): nothing here is a real device")
        m.addLog("\(deviceName): iPhone 16 Pro Max, iOS 26.1")
        m.addLog("Library read: \(m.photoCount) photos, \(m.videoCount) videos (\(m.liveCount) Live Photos), \(DeviceManager.gb(m.totalBytes))")
        m.addLog("Storage: music 19 GB, messages 8 GB, mail 2 GB")
        m.addLog("Blob for iOS 26.1 (23B85) is already saved; keeping it")
    }
}
