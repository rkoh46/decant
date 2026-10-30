import SwiftUI
import ImageCaptureCore
import AVKit
import Photos

@main
struct DecantApp: App {
    @StateObject private var manager = DeviceManager()
    @StateObject private var backups = BackupService()
    @StateObject private var firmware = FirmwareService()
    @StateObject private var apps = AppsService()
    @StateObject private var files = FilesService()

    var body: some Scene {
        WindowGroup("Decant") {
            RootView()
                .environmentObject(manager)
                .environmentObject(backups)
                .environmentObject(firmware)
                .environmentObject(apps)
                .environmentObject(files)
                .frame(minWidth: 1000, minHeight: 760)
        }
        .defaultSize(width: 1180, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Window("Log", id: "log") {
            LogView().environmentObject(manager)
        }
        .defaultSize(width: 600, height: 380)

    }
}

enum Tab { case device, photos, apps, files, backup, firmware, tools }

/// What the Photos sidebar can select: a kind, a year or a file format. Years and formats come from the library itself.
enum PhotoFilter: Hashable {
    case kind(Filter), year(Int), format(String)
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "All Items", photos = "Photos", videos = "Videos", live = "Live Photos"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .photos: return "photo"
        case .videos: return "video"
        case .live: return "livephoto"
        }
    }
}

// Semantic colours, toned to sit inside the neutral ramp.
enum Tone {
    static let ready = Color(red: 0.30, green: 0.76, blue: 0.54)
    static let warning = Color(red: 0.93, green: 0.68, blue: 0.26)
}

// MARK: - Root: top bar with tabs, then the Device dashboard or the Photos pane

struct RootView: View {
    @EnvironmentObject var manager: DeviceManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("destination") private var destination = (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser).path
    @AppStorage("byDate") private var byDate = true
    @AppStorage("skipExisting") private var skipExisting = true
    @AppStorage("deleteAfterCopy") private var deleteAfterCopy = false
    @AppStorage("thumbSize") private var thumbSize = 132.0
    @State private var tab: Tab = ["photos": Tab.photos, "apps": .apps, "files": .files, "backup": .backup, "firmware": .firmware, "tools": .tools][ProcessInfo.processInfo.environment["DECANT_TAB"] ?? ""] ?? .device   // screenshot aid
    @EnvironmentObject var files: FilesService
    @State private var filter: PhotoFilter? = .kind(.all)
    @State private var confirmDelete = false
    @State private var spaceWarning: String?
    @State private var testStarted = false

    var destURL: URL? { destination.isEmpty ? nil : URL(fileURLWithPath: destination) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .device:
                DeviceDashboard(destURL: destURL, copy: { begin(delete: false, all: true) }, move: { begin(delete: true, all: true) },
                                chooseFolder: chooseFolder, showLog: { openWindow(id: "log") })
            case .photos:
                PhotosPane(filter: $filter, thumbSize: $thumbSize, byDate: $byDate, skipExisting: $skipExisting,
                           deleteAfterCopy: $deleteAfterCopy, destURL: destURL, chooseFolder: chooseFolder,
                           showLog: { openWindow(id: "log") }, start: { begin(delete: deleteAfterCopy) })
            case .apps:
                AppsPane(openFiles: { app in
                    files.root = .appDocuments(app.bundleID, app.name); files.path = files.homePath
                    tab = .files
                    if let u = Lockdown.firstUDID() { Task { await files.list(udid: u) } }
                })
            case .files:
                FilesPane()
            case .backup:
                BackupPane(showLog: { openWindow(id: "log") })
            case .firmware:
                FirmwarePane(showLog: { openWindow(id: "log") })
            case .tools:
                ToolsPane(showLog: { openWindow(id: "log") })
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete from iPhone?", isPresented: $confirmDelete) {
            Button("Copy and Delete", role: .destructive) { start(delete: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(manager.canDelete
                 ? "\(manager.selection.count.formatted()) items will be removed from the iPhone after each copy is verified. The iPhone may keep them in Recently Deleted for 30 days."
                 : "\(manager.selection.count.formatted()) items will be removed from your iCloud library and every device after each copy is verified, through the Photos library on this Mac. Recently Deleted keeps them for 30 days.")
        }
        .alert("Not enough space", isPresented: Binding(get: { spaceWarning != nil }, set: { if !$0 { spaceWarning = nil } })) {
            Button("OK") {}
        } message: { Text(spaceWarning ?? "") }
        .onReceive(manager.$catalogComplete) { complete in
            if complete { runTestModeIfRequested() }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 80)                       // room for the traffic lights
            Text("Decant").font(.system(size: 16, weight: .medium))
            Spacer()
            HStack(spacing: 4) {
                TabButton(title: "Device", symbol: "iphone", selected: tab == .device) { tab = .device }
                    .keyboardShortcut("1", modifiers: .command)
                TabButton(title: "Photos", symbol: "photo.on.rectangle", selected: tab == .photos) { tab = .photos }
                    .keyboardShortcut("2", modifiers: .command)
                TabButton(title: "Apps", symbol: "square.grid.2x2", selected: tab == .apps) { tab = .apps }
                    .keyboardShortcut("3", modifiers: .command)
                TabButton(title: "Files", symbol: "folder", selected: tab == .files) { tab = .files }
                    .keyboardShortcut("4", modifiers: .command)
                TabButton(title: "Backup", symbol: "externaldrive", selected: tab == .backup) { tab = .backup }
                    .keyboardShortcut("5", modifiers: .command)
                TabButton(title: "Firmware", symbol: "cpu", selected: tab == .firmware) { tab = .firmware }
                    .keyboardShortcut("6", modifiers: .command)
                TabButton(title: "Tools", symbol: "wrench.and.screwdriver", selected: tab == .tools) { tab = .tools }
                    .keyboardShortcut("7", modifiers: .command)
            }
            Spacer()
            deviceChip
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(.bar)
        .gesture(WindowDragGesture())
    }

    private var deviceChip: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(manager.device?.name ?? "No iPhone").font(.callout)
            if let level = manager.battery?.level {
                Text("\(level)%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        if manager.device == nil { return Color(nsColor: .tertiaryLabelColor) }
        if manager.locked { return Tone.warning }
        return manager.catalogComplete ? Tone.ready : Tone.warning
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if let url = destURL { panel.directoryURL = url }
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    /// From the Photos tab this acts on the selection; from the Device tab (`all`) on the whole library.
    private func begin(delete: Bool, all: Bool = false) {
        if destURL == nil { chooseFolder() }
        guard let url = destURL, manager.catalogComplete, !manager.running else { return }
        if all { manager.selection = Set(manager.items.map { $0.id }) }
        guard !manager.selection.isEmpty else { return }
        if let free = DeviceManager.freeSpace(at: url), free < manager.selectedBytes {
            spaceWarning = "The selection is \(DeviceManager.gb(manager.selectedBytes)) but only \(DeviceManager.gb(free)) is free in \(url.lastPathComponent)."
            return
        }
        if delete { confirmDelete = true } else { start(delete: false) }
    }

    private func start(delete: Bool) {
        guard let url = destURL else { return }
        tab = .photos
        manager.offload(OffloadOptions(destination: url, byDate: byDate, skipExisting: skipExisting, deleteAfterCopy: delete))
    }

    // `Decant --test-offload N /dest`: move the N newest photos through the real engine, re-read the phone,
    // report on stdout and quit. Used to prove a clean copy-verify-delete before a bulk run.
    private func runTestModeIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--match-test"), args.count > i + 1, let n = Int(args[i + 1]), !testStarted {
            testStarted = true
            let report = Self.reporter(FileManager.default.temporaryDirectory.appendingPathComponent("decant-match.log"))
            Task { @MainActor in
                let newest = Array(manager.items.filter { !$0.isVideo }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(n))
                if !PhotoLibraryDeleter.authorized { _ = await PhotoLibraryDeleter.requestAccess() }
                let (found, missing) = PhotoLibraryDeleter.match(newest)
                for item in newest {
                    if let a = found[item] {
                        let libName = PHAssetResource.assetResources(for: a).first?.originalFilename ?? "?"
                        report("MATCH \(item.name) (\(item.pixelWidth)×\(item.pixelHeight)) → \(libName) \(a.pixelWidth)×\(a.pixelHeight) \(a.creationDate?.formatted() ?? "no date")")
                    }
                    else { report("MISSING \(item.name) (phone date \(item.date?.formatted() ?? "none"))") }
                }
                report("MATCH RESULT: \(found.count) of \(newest.count) found, \(missing.count) missing")
                NSApp.terminate(nil)
            }
            return
        }
        if let i = args.firstIndex(of: "--list-newest"), args.count > i + 1, let n = Int(args[i + 1]), !testStarted {
            testStarted = true
            let newest = manager.items.filter { !$0.isVideo }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(n)
            let report = Self.reporter(FileManager.default.temporaryDirectory.appendingPathComponent("decant-newest.log"))
            report("NEWEST (\(manager.items.count) items on phone): " + newest.map { $0.name }.joined(separator: ", "))
            NSApp.terminate(nil); return
        }
        guard !testStarted, let i = args.firstIndex(of: "--test-offload"), args.count > i + 2,
              let n = Int(args[i + 1]) else { return }
        testStarted = true
        let dest = URL(fileURLWithPath: args[i + 2])
        let report = Self.reporter(dest.appendingPathComponent(".decant-test.log"))
        Task { @MainActor in
            let print = report
            let picks = manager.items.filter { !$0.isVideo }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(n)
            let names = picks.map { $0.name }
            print("TEST picking \(names.count) newest photos: \(names.joined(separator: ", "))")
            manager.selection = Set(picks.map { $0.id })
            manager.offload(OffloadOptions(destination: dest, byDate: true, skipExisting: true, deleteAfterCopy: true))
            while manager.running { try? await Task.sleep(nanoseconds: 200_000_000) }
            for p in picks {
                let folder = DeviceManager.dateFolder(dest, p.date).appendingPathComponent(p.name).path
                print("TEST \(p.name): status=\(p.status) phoneSize=\(p.size) diskSize=\(DeviceManager.size(of: URL(fileURLWithPath: folder)) ?? -1) at \(folder)")
            }
            let allDeleted = picks.allSatisfy { $0.status == .deleted }
            if manager.canDelete {
                print("TEST re-reading the iPhone…")
                let before = manager.items.count
                manager.refresh()
                while !manager.catalogComplete { try? await Task.sleep(nanoseconds: 200_000_000) }
                let still = manager.items.filter { names.contains($0.name) }.map { $0.name }
                print("TEST items on phone: \(before) -> \(manager.items.count); still present: \(still.isEmpty ? "none" : still.joined(separator: ", "))")
                print(still.isEmpty && allDeleted ? "TEST RESULT: PASS" : "TEST RESULT: FAIL")
            } else {
                print("TEST iCloud Photos is on: deleted through the Mac's Photos library; the iPhone drops them on its next sync (check with --list-newest)")
                print(allDeleted ? "TEST RESULT: PASS" : "TEST RESULT: FAIL")
            }
            NSApp.terminate(nil)
        }
    }
}

extension RootView {
    /// Test output goes to stdout and to a file, because `open` (needed so macOS can show permission prompts)
    /// does not pass stdout back.
    static func reporter(_ url: URL) -> (String) -> Void {
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return { line in
            Swift.print(line)
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
        }
    }
}

struct TabButton: View {
    let title: String, symbol: String, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.caption)
            }
            .frame(width: 80, height: 44)
            .foregroundStyle(selected ? .primary : .secondary)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))       // the whole tile is the click target
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var fill = false          // stretch to the height offered, content pinned to the top
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

// MARK: - Device dashboard

struct DeviceDashboard: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var apps: AppsService
    @State private var revealSerial = false
    let destURL: URL?
    let copy: () -> Void, move: () -> Void, chooseFolder: () -> Void, showLog: () -> Void

    // The cards fill the window; the photo destination is a fixed footer like the bottom bar on the other tabs.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    phoneCard.frame(width: 272)
                    VStack(spacing: 16) {
                        infoCard
                        storageCard
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 0, alignment: .top)
                .containerRelativeFrame(.vertical) { h, _ in max(h, 420) }
            }
            Divider()
            photosRow
                .padding(.horizontal, 24)
                .frame(height: 60)
                .background(.bar)
        }
    }

    private var phoneCard: some View {
        Card(fill: true) {
            VStack(spacing: 16) {
                PhoneView(style: PhoneStyle.style(for: manager.info?.model, name: manager.info?.marketingName),
                          connected: manager.device != nil, screenItems: manager.screenItems)
                    .padding(.top, 4)
                VStack(spacing: 4) {
                    Text(manager.info?.marketingName ?? manager.device?.productKind ?? "No iPhone")
                        .font(.system(size: 15, weight: .medium))
                    Text(manager.statusText).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Refresh") { manager.refresh() }.disabled(manager.device == nil || manager.running)
                    Button("Log", action: showLog)
                }
                .controlSize(.small)
                Spacer(minLength: 8)
                batteryBlock
            }
            .frame(maxWidth: .infinity)
        }
    }

    // Live battery readings (refreshed every 30 s) under the phone.
    private var batteryBlock: some View {
        let b = manager.battery
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Battery").font(.system(size: 13, weight: .medium))
                Spacer()
                if let c = b?.charging { Text(c ? "Charging" : "On battery").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.bottom, 6)
            smallRow("Level", b?.level.map { "\($0)%" })
            smallRow("Health", b?.health.map { String(format: "%.0f%%", $0) })
            smallRow("Cycles", b?.cycleCount.map { $0.formatted() })
            smallRow("Voltage", b?.voltage.map { String(format: "%.2f V", $0) })
            smallRow("Capacity", (b?.maxCapacity).flatMap { m in b?.designCapacity.map { "\(m) of \($0) mAh" } })
        }
    }

    private func smallRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "–").monospacedDigit()
        }
        .font(.system(size: 12))
        .frame(height: 26)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(manager.info?.marketingName ?? manager.device?.name ?? "No iPhone connected")
                        .font(.system(size: 22, weight: .medium))
                    if let s = manager.storage {
                        Text(Self.capacityLabel(s.capacity)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 0) {
                    GridRow { row("Device name", manager.device?.name); row("Wi-Fi address", blank(manager.info?.wifiAddress)) }
                    GridRow { row("iOS version", blank(manager.info?.version)); row("Bluetooth address", blank(manager.info?.bluetoothAddress)) }
                    GridRow { row("Model", blank(manager.info?.model)); row("Model number", modelNumber) }
                    GridRow { serialRow; row("Region", blank(manager.info?.region)) }
                    GridRow { row("Connection", manager.device == nil ? nil : "USB"); row("Status", manager.device == nil ? nil : manager.statusWord) }
                    GridRow { row("Photos", num(manager.photoCount)); row("Videos", num(manager.videoCount)) }
                    GridRow { row("Live Photos", num(manager.liveCount)); row("Camera roll", manager.device == nil ? nil : DeviceManager.gb(manager.totalBytes)) }
                }
                if manager.device != nil && !Lockdown.available {
                    Text("Install libimobiledevice (brew install libimobiledevice) for iOS version, serial, battery health and storage")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func blank(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
    private func num(_ n: Int) -> String? { manager.device == nil ? nil : n.formatted() }

    private var modelNumber: String? {
        guard let i = manager.info, !i.modelNumber.isEmpty else { return nil }
        return i.modelNumber + i.region            // MU6C3 + LL/A, as printed on the box
    }

    private var batteryText: String? {
        guard let b = manager.battery, let level = b.level else { return nil }
        return "\(level)%" + (b.charging == true ? ", charging" : "")
    }

    private var healthText: String? {
        guard let b = manager.battery else { return nil }
        var parts: [String] = []
        if let h = b.health { parts.append(String(format: "%.0f%%", h)) }
        if let c = b.cycleCount { parts.append("\(c.formatted()) cycles") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            Text(value ?? "–").fontWeight(.medium).monospacedDigit().lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }

    // Serial number stays masked until the eye is clicked (screenshots, screen sharing).
    private var serialRow: some View {
        HStack(spacing: 8) {
            Text("Serial number").foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            if let serial = blank(manager.info?.serial) {
                Text(revealSerial ? serial : String(repeating: "•", count: serial.count))
                    .fontWeight(.medium).monospaced().lineLimit(1)
                Button { revealSerial.toggle() } label: {
                    Image(systemName: revealSerial ? "eye.slash" : "eye").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).help(revealSerial ? "Hide serial number" : "Show serial number")
            } else {
                Text("–").fontWeight(.medium)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var storageCard: some View {
        Card(fill: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Storage").font(.system(size: 15, weight: .medium))
                    Spacer()
                    if let s = manager.storage {
                        Text("\(DeviceManager.gb(s.capacity - s.free)) used of \(DeviceManager.gb(s.capacity))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    } else if manager.device != nil {
                        Text("Camera roll \(DeviceManager.gb(manager.totalBytes))").font(.callout).foregroundStyle(.secondary)
                    }
                }
                let photos = Double(manager.storage?.photos ?? manager.totalBytes)
                let cap = Double(manager.storage?.capacity ?? 0)
                let free = Double(manager.storage?.free ?? 0)
                let other = max(cap - free - photos, 0)
                GeometryReader { g in
                    HStack(spacing: 2) {
                        if cap > 0 {
                            Rectangle().fill(Color.accentColor).frame(width: max(g.size.width * photos / cap, 2))
                            Rectangle().fill(Color(nsColor: .tertiaryLabelColor)).frame(width: g.size.width * other / cap)
                        }
                        Rectangle().fill(.quaternary)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 12)
                let appBytes = apps.apps.reduce(0) { $0 + $1.totalSize }
                let system = Double(manager.storage?.system ?? 0)
                let rest = max(other - Double(appBytes) - system, 0)
                HStack(spacing: 20) {
                    legend(Color.accentColor, "Photos & videos", manager.device == nil ? nil : (manager.storage?.photos ?? manager.totalBytes))
                    legend(Color(nsColor: .tertiaryLabelColor), "Other", cap > 0 ? Int(other) : nil)
                    legend(Color(nsColor: .quaternaryLabelColor), "Free", cap > 0 ? Int(free) : nil)
                    Spacer()
                }
                .font(.system(size: 12))
                if cap > 0 {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Breakdown").font(.system(size: 13, weight: .medium)).padding(.top, 8).padding(.bottom, 6)
                            smallRow("Photos & videos", DeviceManager.gb(Int(photos)))
                            smallRow("Apps and their data", appBytes > 0 ? DeviceManager.gb(appBytes) : (apps.measuring || apps.loading ? "measuring…" : "–"))
                            smallRow("iOS", system > 0 ? DeviceManager.gb(Int(system)) : "–")
                            smallRow("Messages, mail, caches", appBytes > 0 ? DeviceManager.gb(Int(rest)) : "–")
                            smallRow("Free", DeviceManager.gb(Int(free)))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Largest apps").font(.system(size: 13, weight: .medium)).padding(.top, 8).padding(.bottom, 6)
                            if appBytes == 0 {
                                Text(apps.measuring || apps.loading ? "Measuring…" : "Open Apps to measure").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 26)
                            }
                            ForEach(appBytes > 0 ? Array(apps.apps.prefix(5)) : []) { app in
                                HStack(spacing: 8) {
                                    if let img = apps.icons[app.bundleID] {
                                        Image(nsImage: img).resizable().frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                                    } else {
                                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 18, height: 18)
                                    }
                                    Text(app.name).lineLimit(1)
                                    Spacer()
                                    Text(DeviceManager.gb(app.totalSize)).monospacedDigit()
                                }
                                .font(.system(size: 12))
                                .frame(height: 26)
                                .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: manager.catalogComplete) { ok in
            if ok, apps.apps.isEmpty, !apps.loading, let u = Lockdown.cachedUDID { Task { await apps.load(udid: u, includeSystem: false) } }
        }
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(bytes.map(DeviceManager.gb) ?? "–").monospacedDigit()
        }
    }

    static func capacityLabel(_ bytes: Int) -> String {
        // Marketed sizes: round to the nearest 64 / 128 / 256 / 512 GB / 1 TB.
        let gb = Double(bytes) / 1e9
        let tiers: [Double] = [64, 128, 256, 512, 1024, 2048]
        let t = tiers.min { abs($0 - gb) < abs($1 - gb) } ?? gb
        return t >= 1024 ? "\(Int(t / 1024)) TB" : "\(Int(t)) GB"
    }

    // Where photos go, and the two photo actions. The primary action is the only accent on the screen.
    private var photosRow: some View {
        HStack(spacing: 8) {
            Text("Photos go to").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            if let url = destURL {
                Text(Self.shortPath(url)).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Button("Change…", action: chooseFolder).buttonStyle(.link)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                if let free = DeviceManager.freeSpace(at: url) {
                    Text("\(DeviceManager.gb(free)) free").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Button("Choose a folder…", action: chooseFolder).buttonStyle(.link)
            }
            Spacer()
            Button("Move All to Mac…", action: move)
            Button("Copy All to Mac", action: copy).buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .disabled(manager.running)
    }

    static func shortPath(_ url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" && $0 != "Volumes" && $0 != "Users" }
        return parts.suffix(3).joined(separator: " › ")
    }
}

// MARK: - Phone render: shape follows the connected model, the screen shows the camera roll

struct PhoneView: View {
    let style: PhoneStyle
    let connected: Bool
    let screenItems: [MediaItem]

    var body: some View {
        let w = style.fold ? style.width * 1.5 : style.width
        let h = style.height
        let screenInset = EdgeInsets(top: style.homeButton ? 40 : style.bezel, leading: style.bezel,
                                     bottom: style.homeButton ? 40 : style.bezel, trailing: style.bezel)
        ZStack {
            // Body: one neutral with a slight tone shift, a hairline rim for the metal edge.
            RoundedRectangle(cornerRadius: style.corner)
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: style.corner).strokeBorder(Color(white: 1, opacity: 0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            // Screen
            screen
                .clipShape(RoundedRectangle(cornerRadius: max(style.corner - style.bezel, 4)))
                .padding(screenInset)
            if style.fold {
                Rectangle().fill(Color(white: 1, opacity: 0.10)).frame(width: 1).padding(.vertical, style.bezel)
            }
            // Cutout
            VStack {
                switch style.cutout {
                case .island: Capsule().fill(.black).frame(width: w * 0.30, height: 11).padding(.top, style.bezel + 8)
                case .notch: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: w * 0.46, height: 16).padding(.top, style.bezel)
                case .none: EmptyView()
                }
                Spacer()
                if style.homeButton {
                    Circle().strokeBorder(Color(white: 1, opacity: 0.25), lineWidth: 1.5).frame(width: 26, height: 26).padding(.bottom, 7)
                }
            }
        }
        .frame(width: w, height: h)
        .opacity(connected ? 1 : 0.55)
    }

    @ViewBuilder private var screen: some View {
        let thumbs = screenItems.filter { $0.thumbnail != nil }
        if connected && thumbs.count >= 3 {
            // The camera roll itself, three across, newest first.
            let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: 3)
            GeometryReader { g in
                let side = (g.size.width - 2) / 3
                LazyVGrid(columns: cols, spacing: 1) {
                    ForEach(thumbs.prefix(18)) { item in
                        ScreenThumb(item: item).frame(width: side, height: side).clipped()
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                .background(.black)
            }
        } else {
            // Dark glass with one soft reflection.
            ZStack {
                LinearGradient(colors: [Color(white: 0.13), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [Color(white: 1, opacity: 0.07), .clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                if !connected {
                    Image(systemName: "cable.connector").font(.system(size: 28, weight: .light)).foregroundStyle(Color(white: 0.45))
                }
            }
        }
    }
}

struct ScreenThumb: View {
    @ObservedObject var item: MediaItem
    var body: some View {
        if let t = item.thumbnail {
            Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color(white: 0.1)
        }
    }
}

// MARK: - Photos pane: filter list, grid, Image Capture-style bottom bar

struct PhotosPane: View {
    @EnvironmentObject var manager: DeviceManager
    @Binding var filter: PhotoFilter?
    @Binding var thumbSize: Double
    @Binding var byDate: Bool
    @Binding var skipExisting: Bool
    @Binding var deleteAfterCopy: Bool
    let destURL: URL?
    let chooseFolder: () -> Void, showLog: () -> Void, start: () -> Void
    @State private var viewing: MediaItem? = nil
    @State private var deleting: MediaItem? = nil
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var marquee: CGRect? = nil
    @State private var marqueeBase: Set<String> = []
    @State private var lastClicked: String? = nil
    @State private var gridOrigin: CGPoint = .zero          // grid's top-left in viewport coordinates (scroll offset)
    @State private var viewportSize: CGSize = .zero
    @State private var dragStartContent: CGPoint? = nil      // where the marquee began, in grid (content) coordinates
    @State private var pointerInViewport: CGPoint = .zero
    @StateObject private var autoscroll = AutoScroller()
    @StateObject private var scrollHolder = ScrollViewHolder()
    @State private var edgeDepth: CGFloat = 0                 // 0 at the edge zone's inner border, 1 at the viewport edge

    private func count(_ f: Filter) -> Int {
        switch f {
        case .all: return manager.items.count
        case .photos: return manager.photoCount
        case .videos: return manager.videoCount
        case .live: return manager.liveCount
        }
    }

    static func format(of item: MediaItem) -> String {
        switch (item.name as NSString).pathExtension.lowercased() {
        case "heic", "heif": return "HEIC"
        case "jpg", "jpeg": return "JPEG"
        case "png": return "PNG"
        case "gif": return "GIF"
        case "dng": return "RAW"
        case "mov": return "MOV"
        case "mp4", "m4v": return "MP4"
        case let e where e.isEmpty: return "Other"
        case let e: return e.uppercased()
        }
    }

    private static func year(of item: MediaItem) -> Int? { item.date.map { Calendar.current.component(.year, from: $0) } }

    /// Years newest first, formats by count; both with their counts.
    private var years: [(Int, Int)] {
        var c: [Int: Int] = [:]
        for i in manager.items { if let y = Self.year(of: i) { c[y, default: 0] += 1 } }
        return c.sorted { $0.key > $1.key }
    }
    private var formats: [(String, Int)] {
        var c: [String: Int] = [:]
        for i in manager.items { c[Self.format(of: i), default: 0] += 1 }
        return c.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }

    private var shown: [MediaItem] {
        let list: [MediaItem]
        switch filter ?? .kind(.all) {
        case .kind(.all): list = manager.items
        case .kind(.photos): list = manager.items.filter { !$0.isVideo }
        case .kind(.videos): list = manager.items.filter { $0.isVideo }
        case .kind(.live): list = manager.items.filter { $0.isLivePhoto }
        case .year(let y): list = manager.items.filter { Self.year(of: $0) == y }
        case .format(let f): list = manager.items.filter { Self.format(of: $0) == f }
        }
        return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private func sidebarRow(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if manager.device != nil { Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $filter) {
                Section("Library") {
                    ForEach(Filter.allCases) { f in
                        sidebarRow(f.rawValue, symbol: f.symbol, count: count(f)).tag(PhotoFilter.kind(f))
                    }
                }
                if !years.isEmpty {
                    Section("Years") {
                        ForEach(years, id: \.0) { y, n in
                            sidebarRow(String(y), symbol: "calendar", count: n).tag(PhotoFilter.year(y))
                        }
                    }
                }
                if formats.count > 1 {
                    Section("Formats") {
                        ForEach(formats, id: \.0) { f, n in
                            sidebarRow(f, symbol: "doc", count: n).tag(PhotoFilter.format(f))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                gridToolbar
                Divider()
                grid
                Divider()
                bottomBar
            }
        }
    }

    private var gridToolbar: some View {
        HStack(spacing: 12) {
            Text("\(shown.count.formatted()) items · \(manager.selection.count.formatted()) selected")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Slider(value: $thumbSize, in: 80...220).frame(width: 112).help("Thumbnail size")
            Button("Select All") { manager.selection.formUnion(shown.map { $0.id }) }.disabled(shown.isEmpty)
                .keyboardShortcut("a", modifiers: .command)
            Button("Select None") { manager.selection.subtract(shown.map { $0.id }) }.disabled(manager.selection.isEmpty)
            Menu {
                Toggle("Sort into Year/Month Folders", isOn: $byDate)
                Toggle("Skip Files Already in Destination", isOn: $skipExisting)
                Divider()
                Button("Show Log", action: showLog)
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .disabled(manager.running)
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var grid: some View {
        Group {
            if manager.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: manager.locked ? "lock.iphone" : "iphone.and.arrow.forward")
                        .font(.system(size: 48, weight: .light)).foregroundStyle(.tertiary)
                    Text(manager.statusText).foregroundStyle(.secondary)
                    if manager.device != nil && !manager.catalogComplete && !manager.locked { ProgressView().controlSize(.small) }
                    if manager.device != nil && !manager.sessionOpen && !manager.locked {
                        VStack(spacing: 6) {
                            Button("Retry") { manager.retryConnection() }.padding(.top, 4)
                            if manager.connectAttempts >= 3 {
                                Text("Still nothing after three tries: unplug and replug the cable").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { outer in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize), spacing: 4)], spacing: 4) {
                                ForEach(shown) { item in
                                    ThumbCell(item: item, size: thumbSize, selected: manager.selection.contains(item.id))
                                        .background(GeometryReader { g in
                                            Color.clear.preference(key: CellFramesKey.self, value: [item.id: g.frame(in: .named("grid"))])
                                        })
                                        .id(item.id)
                                        .onTapGesture(count: 2) { viewing = item }
                                        .onTapGesture { click(item) }
                                        .contextMenu {
                                            Button("View") { viewing = item }
                                            Button(manager.selection.contains(item.id) ? "Deselect" : "Select") { toggle(item) }
                                            Divider()
                                            Button("Copy This Item to Mac") {
                                                guard let url = destURL else { chooseFolder(); return }
                                                manager.offload(OffloadOptions(destination: url, byDate: byDate, skipExisting: skipExisting, deleteAfterCopy: false), only: [item])
                                            }
                                            .disabled(manager.running)
                                            Divider()
                                            Button(manager.canDelete ? "Delete from iPhone…" : "Delete via iCloud…", role: .destructive) { deleting = item }
                                                .disabled(manager.running || item.status == .deleted)
                                        }
                                }
                            }
                            .padding(8)
                            .coordinateSpace(name: "grid")
                            .background(ScrollViewFinder(holder: scrollHolder))
                            .background(GeometryReader { g in
                                Color.clear.preference(key: GridOriginKey.self, value: g.frame(in: .named("viewport")).origin)
                            })
                            .onPreferenceChange(CellFramesKey.self) { cellFrames.merge($0) { _, new in new } }
                            .onPreferenceChange(GridOriginKey.self) { gridOrigin = $0 }
                            .overlay {
                                if let m = marquee {
                                    Rectangle().fill(Color.accentColor.opacity(0.12))
                                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                                        .frame(width: m.width, height: m.height)
                                        .position(x: m.midX, y: m.midY)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        .coordinateSpace(name: "viewport")
                        // Drag across the grid to select everything the rectangle touches (shift adds to the selection).
                        // Near the top or bottom edge the grid scrolls by itself and the rectangle keeps growing.
                        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("viewport"))
                            .onChanged { v in
                                guard !manager.running else { return }
                                if dragStartContent == nil {
                                    marqueeBase = NSEvent.modifierFlags.contains(.shift) ? manager.selection : []
                                    let off = scrollOffset
                                    dragStartContent = CGPoint(x: v.startLocation.x + off.x, y: v.startLocation.y + off.y)
                                }
                                pointerInViewport = v.location
                                updateMarquee()
                                let edge: CGFloat = 72
                                if v.location.y > viewportSize.height - edge {
                                    edgeDepth = min(1, (v.location.y - (viewportSize.height - edge)) / edge)
                                    autoscroll.start(direction: 1) { autoscrollStep(proxy, 1) }
                                } else if v.location.y < edge {
                                    edgeDepth = min(1, (edge - v.location.y) / edge)
                                    autoscroll.start(direction: -1) { autoscrollStep(proxy, -1) }
                                } else { autoscroll.stop() }
                            }
                            .onEnded { _ in autoscroll.stop(); marquee = nil; dragStartContent = nil })
                        .onChange(of: outer.size) { viewportSize = $0 }
                        .onAppear { viewportSize = outer.size }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $viewing) { item in
            PreviewSheet(items: shown, current: item) { viewing = nil }
                .environmentObject(manager)
        }
        .alert("Delete \(deleting?.name ?? "this item") from the iPhone?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let d = deleting { manager.deleteFromPhone([d]) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(manager.canDelete
                 ? "It is not copied to the Mac first. The iPhone may keep it in Recently Deleted for 30 days."
                 : "iCloud Photos is on, so this deletes it from your iCloud library and every device, through the Photos library on this Mac. It is not copied to the Mac first. Recently Deleted keeps it for 30 days.")
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["DECANT_PREVIEW"] == "1", let first = shown.first { viewing = first }   // screenshot aid
        }
    }

    private func toggle(_ item: MediaItem) {
        guard !manager.running else { return }
        if manager.selection.contains(item.id) { manager.selection.remove(item.id) } else { manager.selection.insert(item.id) }
    }

    /// Where the content is scrolled to, from the real scroll view when we have it (the preference lags a frame).
    private var scrollOffset: CGPoint {
        if let sv = scrollHolder.scrollView { return sv.contentView.bounds.origin }
        return CGPoint(x: -gridOrigin.x, y: -gridOrigin.y)
    }

    private func updateMarquee() {
        guard let start = dragStartContent else { return }
        let off = scrollOffset
        let current = CGPoint(x: pointerInViewport.x + off.x, y: pointerInViewport.y + off.y)
        let r = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
        marquee = r
        manager.selection = marqueeBase.union(cellFrames.filter { $0.value.intersects(r) }.map { $0.key })
    }

    /// Move the real scroll view a step in the drag's direction, then grow the selection into the new rows.
    private func autoscrollStep(_ proxy: ScrollViewProxy, _ direction: Int) {
        guard let sv = scrollHolder.scrollView, let doc = sv.documentView else { autoscroll.stop(); return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        let maxY = max(0, doc.bounds.height - clip.bounds.height)
        let step = 10 + 50 * max(edgeDepth, 0)                // 600 to 3600 points per second at 60 ticks
        let next = min(max(0, o.y + CGFloat(direction) * step), maxY)
        if next == o.y { autoscroll.stop(); return }
        o.y = next
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
        updateMarquee()
    }

    /// Click toggles one item; shift-click selects the run between the last click and this one.
    private func click(_ item: MediaItem) {
        guard !manager.running else { return }
        let order = shown
        if NSEvent.modifierFlags.contains(.shift), let last = lastClicked,
           let a = order.firstIndex(where: { $0.id == last }), let b = order.firstIndex(where: { $0.id == item.id }) {
            manager.selection.formUnion(order[min(a, b)...max(a, b)].map { $0.id })
        } else {
            toggle(item)
        }
        lastClicked = item.id
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if manager.running {
                ProgressView(value: manager.progress.fraction).frame(maxWidth: 320)
                Text(progressText).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer()
                Button("Stop") { manager.cancel() }
            } else {
                Text("Import to").foregroundStyle(.secondary)
                Button(action: chooseFolder) {
                    Label(destURL?.lastPathComponent ?? "Choose Folder…", systemImage: "folder")
                }
                if let url = destURL, let free = DeviceManager.freeSpace(at: url) {
                    Text("\(DeviceManager.gb(free)) free").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if let summary = manager.summary {
                    Divider().frame(height: 16)
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let url = destURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                    }
                }
                Spacer()
                Toggle(manager.canDelete ? "Delete after import" : "Delete via iCloud after import", isOn: $deleteAfterCopy)
                    .help(manager.canDelete ? "" : "iCloud Photos is on: deletes go through the Photos library on this Mac and sync to the iPhone")
                Button(action: start) {
                    Text(copyButtonTitle).frame(minWidth: 120)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(manager.device == nil || !manager.catalogComplete || manager.selection.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.bar)
    }

    private var copyButtonTitle: String {
        let n = manager.selection.count
        let items = n == 1 ? "Item" : "Items"
        return deleteAfterCopy ? "Move \(n.formatted()) \(items)" : "Copy \(n.formatted()) \(items)"
    }

    private var progressText: String {
        let p = manager.progress
        return "\(p.phase) \(p.done.formatted()) of \(p.total.formatted()) · \(DeviceManager.gb(p.bytesDone)) of \(DeviceManager.gb(p.bytesTotal))"
    }
}

/// Finds the AppKit scroll view that hosts the grid, so a drag can scroll it directly.
final class ScrollViewHolder: ObservableObject { weak var scrollView: NSScrollView? }

struct ScrollViewFinder: NSViewRepresentable {
    let holder: ScrollViewHolder
    final class Probe: NSView {
        weak var holder: ScrollViewHolder?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); holder?.scrollView = enclosingScrollView }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Probe { let p = Probe(); p.holder = holder; return p }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.holder = holder; if nsView.window != nil { holder.scrollView = nsView.enclosingScrollView } }
}

struct GridOriginKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// Repeats a scroll step while the pointer stays near an edge during a drag.
final class AutoScroller: ObservableObject {
    private var timer: Timer?
    private var direction = 0
    func start(direction: Int, step: @escaping () -> Void) {
        if timer != nil && self.direction == direction { return }
        stop()
        self.direction = direction
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in step() }
        RunLoop.main.add(timer!, forMode: .common)      // keeps ticking while the mouse button is held
    }
    func stop() { timer?.invalidate(); timer = nil; direction = 0 }
}

struct CellFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

// MARK: - Viewer: the item at full size, fetched from the phone on demand

struct PreviewSheet: View {
    @EnvironmentObject var manager: DeviceManager
    let items: [MediaItem]
    @State var current: MediaItem
    let close: () -> Void
    @State private var url: URL?
    @State private var failed = false
    @State private var player: AVPlayer?

    private var index: Int { items.firstIndex(of: current) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let url {
                    if current.isVideo {
                        VideoPlayer(player: player).onAppear { player = AVPlayer(url: url); player?.play() }
                    } else if let img = NSImage(contentsOf: url) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        unavailable
                    }
                } else if failed {
                    unavailable
                } else {
                    VStack(spacing: 12) {
                        if let t = current.thumbnail {
                            Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit).blur(radius: 6).opacity(0.5)
                        }
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    arrow("chevron.left", enabled: index > 0) { step(-1) }
                    Spacer()
                    arrow("chevron.right", enabled: index < items.count - 1) { step(1) }
                }
                .padding(12)
            }
            .frame(minWidth: 960, minHeight: 600)
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.name).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Text("\(index + 1) of \(items.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.bar)
        }
        .task(id: current.id) { await load() }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { if current.isVideo, let p = player { p.rate == 0 ? p.play() : p.pause() }; return .handled }
    }

    private var detail: String {
        var parts = [DeviceManager.gb(current.size)]
        if let d = current.date { parts.append(d.formatted(date: .long, time: .shortened)) }
        if current.isVideo { parts.append(ThumbCell.clock(current.duration)) }
        if current.isLivePhoto { parts.append("Live Photo") }
        return parts.joined(separator: " · ")
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("Could not load this item from the iPhone").foregroundStyle(.secondary)
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0).disabled(!enabled)
    }

    private func step(_ by: Int) {
        let i = index + by
        guard items.indices.contains(i) else { return }
        player?.pause(); player = nil
        url = nil; failed = false
        current = items[i]
    }

    private func load() async {
        url = nil; failed = false
        if let u = await manager.previewURL(for: current) { url = u } else { failed = true }
    }
}

// MARK: - Thumbnail tile

struct ThumbCell: View {
    @ObservedObject var item: MediaItem
    let size: Double
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Group {
                if let t = item.thumbnail {
                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: size, height: size).clipped()

            VStack {
                HStack {
                    if item.isLivePhoto {
                        Label("Live", systemImage: "livephoto").labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).frame(height: 18)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor).font(.title3)
                    } else if hovering {
                        Image(systemName: "circle").foregroundStyle(.white).font(.title3).shadow(radius: 1)
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    if item.isVideo {
                        Text(Self.clock(item.duration)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 2)
                    }
                    statusBadge
                }
            }
            .padding(6)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
        .opacity(item.status == .deleted ? 0.3 : 1)
        .onHover { hovering = $0 }
        .help(item.name)
        .onAppear { if item.thumbnail == nil && item.thumbnailTries <= 4 { item.file.requestThumbnail() } }
    }

    @ViewBuilder private var statusBadge: some View {
        switch item.status {
        case .pending: EmptyView()
        case .copying: ProgressView().controlSize(.mini)
        case .verified, .alreadyCopied:
            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Tone.ready)
        case .deleted:
            Image(systemName: "trash.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning).shadow(radius: 1)
        }
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Log window

struct LogView: View {
    @EnvironmentObject var manager: DeviceManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(manager.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.body, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: manager.log.count) { _ in
                if let last = manager.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}
