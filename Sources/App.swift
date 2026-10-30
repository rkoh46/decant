import SwiftUI
import ImageCaptureCore

@main
struct DecantApp: App {
    @StateObject private var manager = DeviceManager()

    var body: some Scene {
        WindowGroup("Decant") {
            RootView()
                .environmentObject(manager)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Window("Log", id: "log") {
            LogView().environmentObject(manager)
        }
        .defaultSize(width: 600, height: 380)
    }
}

enum Tab { case device, photos }

enum Filter: String, CaseIterable, Identifiable {
    case all = "All Items", photos = "Photos", videos = "Videos", live = "Live Photos"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle.angled"
        case .photos: return "photo"
        case .videos: return "video"
        case .live: return "livephoto"
        }
    }
}

// MARK: - Root: custom top bar with tabs, then the Device dashboard or the Photos pane

struct RootView: View {
    @EnvironmentObject var manager: DeviceManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("destination") private var destination = ""
    @AppStorage("byDate") private var byDate = true
    @AppStorage("skipExisting") private var skipExisting = true
    @AppStorage("deleteAfterCopy") private var deleteAfterCopy = false
    @AppStorage("thumbSize") private var thumbSize = 132.0
    @State private var tab: Tab = ProcessInfo.processInfo.environment["DECANT_TAB"] == "photos" ? .photos : .device   // screenshot aid
    @State private var filter: Filter? = .all
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
                DeviceDashboard(destURL: destURL, copy: { begin(delete: false) }, move: { begin(delete: true) },
                                chooseFolder: chooseFolder, showLog: { openWindow(id: "log") })
            case .photos:
                PhotosPane(filter: $filter, thumbSize: $thumbSize, byDate: $byDate, skipExisting: $skipExisting,
                           deleteAfterCopy: $deleteAfterCopy, destURL: destURL, chooseFolder: chooseFolder,
                           showLog: { openWindow(id: "log") }, start: { begin(delete: deleteAfterCopy) })
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete from iPhone?", isPresented: $confirmDelete) {
            Button("Copy and Delete", role: .destructive) { start(delete: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(manager.selection.count) items will be removed from the iPhone after each copy is verified. The iPhone may keep them in Recently Deleted for 30 days.")
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
            Color.clear.frame(width: 78)                       // room for the traffic lights
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("Decant").font(.title3.weight(.semibold))
            }
            Spacer()
            HStack(spacing: 4) {
                TabButton(title: "Device", symbol: "iphone", selected: tab == .device) { tab = .device }
                    .keyboardShortcut("1", modifiers: .command)
                TabButton(title: "Photos", symbol: "photo.on.rectangle.angled", selected: tab == .photos) { tab = .photos }
                    .keyboardShortcut("2", modifiers: .command)
            }
            Spacer()
            deviceChip
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(.bar)
        .gesture(WindowDragGesture())
    }

    private var deviceChip: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(manager.device?.name ?? "No iPhone").font(.callout.weight(.medium))
            if let level = manager.battery?.level {
                Label("\(level)%", systemImage: level > 60 ? "battery.100percent" : level > 25 ? "battery.50percent" : "battery.25percent")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.quinary, in: Capsule())
    }

    private var statusColor: Color {
        if manager.device == nil { return .gray }
        if manager.locked { return .orange }
        return manager.catalogComplete ? .green : .yellow
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

    private func begin(delete: Bool) {
        if destURL == nil { chooseFolder() }
        guard let url = destURL, manager.catalogComplete, !manager.running else { return }
        if manager.selection.isEmpty { manager.selection = Set(manager.items.map { $0.id }) }
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
        guard !testStarted, let i = args.firstIndex(of: "--test-offload"), args.count > i + 2,
              let n = Int(args[i + 1]) else { return }
        testStarted = true
        let dest = URL(fileURLWithPath: args[i + 2])
        Task { @MainActor in
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
            print("TEST re-reading the iPhone…")
            let before = manager.items.count
            manager.refresh()
            while !manager.catalogComplete { try? await Task.sleep(nanoseconds: 200_000_000) }
            let still = manager.items.filter { names.contains($0.name) }.map { $0.name }
            print("TEST items on phone: \(before) -> \(manager.items.count); still present: \(still.isEmpty ? "none" : still.joined(separator: ", "))")
            print(still.isEmpty && picks.allSatisfy { $0.status == .deleted } ? "TEST RESULT: PASS" : "TEST RESULT: FAIL")
            NSApp.terminate(nil)
        }
    }
}

struct TabButton: View {
    let title: String, symbol: String, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(title).font(.caption)
            }
            .frame(width: 82, height: 48)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Device dashboard (3uTools-style)

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

struct DeviceDashboard: View {
    @EnvironmentObject var manager: DeviceManager
    @State private var revealSerial = false
    let destURL: URL?
    let copy: () -> Void, move: () -> Void, chooseFolder: () -> Void, showLog: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    phoneCard.frame(width: 260)
                    VStack(spacing: 18) {
                        infoCard
                        storageCard
                    }
                }
                quickActions
            }
            .padding(20)
        }
    }

    private var phoneCard: some View {
        Card {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30)
                        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 150, height: 310)
                        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(Color(white: 0.35), lineWidth: 1.5))
                    RoundedRectangle(cornerRadius: 24)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.9), Color.purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 136, height: 296)
                        .opacity(manager.device == nil ? 0.25 : 1)
                    Capsule().fill(.black).frame(width: 46, height: 13).offset(y: -133)
                    Image(systemName: manager.device == nil ? "cable.connector" : "photo.on.rectangle.angled")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 4)
                VStack(spacing: 3) {
                    Text(manager.info?.marketingName ?? manager.device?.productKind ?? "No iPhone").font(.headline)
                    Text(manager.statusText).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh") { manager.refresh() }.disabled(manager.device == nil || manager.running)
                    Button("Log", action: showLog)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(manager.info?.marketingName ?? manager.device?.name ?? "No iPhone connected")
                        .font(.title2.weight(.semibold))
                    if let s = manager.storage {
                        Text(Self.capacityLabel(s.capacity))
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 0) {
                    GridRow { row("Device Name", manager.device?.name); row("Battery", batteryText) }
                    GridRow { row("iOS Version", manager.info?.version); row("Battery Health", healthText) }
                    GridRow { row("Model", modelText); row("Capacity", manager.storage.map { Self.capacityLabel($0.capacity) }) }
                    GridRow { row("Model Number", blank(manager.info?.modelNumber)); row("Region", blank(manager.info?.region)) }
                    GridRow { serialRow; row("Manufacturer", blank(manager.info?.manufacturer)) }
                    GridRow { row("Connection", manager.device == nil ? nil : "USB"); row("Status", manager.device == nil ? nil : manager.statusText) }
                    GridRow { row("Photos", num(manager.photoCount)); row("Videos", num(manager.videoCount)) }
                    GridRow { row("Live Photos", num(manager.liveCount)); row("Camera Roll", manager.device == nil ? nil : DeviceManager.gb(manager.totalBytes)) }
                }
                if manager.device != nil && !Lockdown.available {
                    Text("Install libimobiledevice (brew install libimobiledevice) for iOS version, serial, battery health and storage.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
    }

    private func blank(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    private var modelText: String? {
        guard let i = manager.info, !i.model.isEmpty else { return nil }
        return i.marketingName == i.model ? i.model : "\(i.marketingName) (\(i.model))"
    }

    private var batteryText: String? {
        guard let b = manager.battery, let level = b.level else { return nil }
        return "\(level)%" + (b.charging == true ? " · charging" : "")
    }

    private var healthText: String? {
        guard let b = manager.battery else { return nil }
        var parts: [String] = []
        if let h = b.health { parts.append(String(format: "%.0f%% max capacity", h)) }
        if let c = b.cycleCount { parts.append("\(c) cycles") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // Serial number stays masked until the eye is clicked (screenshots, screen sharing).
    private var serialRow: some View {
        HStack(spacing: 8) {
            Text("Serial Number").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            if let serial = blank(manager.info?.serial) {
                Text(revealSerial ? serial : String(repeating: "•", count: serial.count))
                    .fontWeight(.medium).monospaced().lineLimit(1)
                Button { revealSerial.toggle() } label: {
                    Image(systemName: revealSerial ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).help(revealSerial ? "Hide serial number" : "Show serial number")
            } else {
                Text("–").fontWeight(.medium)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func num(_ n: Int) -> String? { manager.device == nil ? nil : n.formatted() }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value ?? "–").fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var storageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Storage").font(.headline)
                    Spacer()
                    if let s = manager.storage {
                        Text("\(DeviceManager.gb(s.capacity - s.free)) used of \(DeviceManager.gb(s.capacity))")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if manager.device != nil {
                        Text("Camera roll \(DeviceManager.gb(manager.totalBytes))").font(.callout).foregroundStyle(.secondary)
                    }
                }
                let photos = Double(manager.storage?.photos ?? manager.totalBytes)
                let cap = Double(manager.storage?.capacity ?? 0)
                let free = Double(manager.storage?.free ?? 0)
                let other = max(cap - free - photos, 0)
                GeometryReader { g in
                    HStack(spacing: 1) {
                        if cap > 0 {
                            Rectangle().fill(Color.accentColor).frame(width: g.size.width * photos / cap)
                            Rectangle().fill(Color.purple.opacity(0.75)).frame(width: g.size.width * other / cap)
                            Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                        } else {
                            Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 14)
                HStack(spacing: 18) {
                    legend(Color.accentColor, "Photos & Videos", manager.device == nil ? nil : (manager.storage?.photos ?? manager.totalBytes))
                    legend(Color.purple.opacity(0.75), "Other", cap > 0 ? Int(other) : nil)
                    legend(Color(nsColor: .quaternaryLabelColor), "Free", cap > 0 ? Int(free) : nil)
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(bytes.map(DeviceManager.gb) ?? "–").fontWeight(.medium)
        }
    }

    static func capacityLabel(_ bytes: Int) -> String {
        // Marketed sizes: round to the nearest 64 / 128 / 256 / 512 GB / 1 TB.
        let gb = Double(bytes) / 1e9
        let tiers: [Double] = [64, 128, 256, 512, 1024, 2048]
        let t = tiers.min { abs($0 - gb) < abs($1 - gb) } ?? gb
        return t >= 1024 ? "\(Int(t / 1024))TB" : "\(Int(t))GB"
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            ActionTile(title: "Copy to Mac", symbol: "arrow.down.doc", tint: .accentColor, action: copy)
            ActionTile(title: "Move to Mac", symbol: "arrow.down.doc.fill", tint: .red, action: move)
            ActionTile(title: destURL == nil ? "Choose Folder" : "Open Folder", symbol: "folder", tint: .orange,
                       subtitle: destURL?.lastPathComponent) {
                if let url = destURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { chooseFolder() }
            }
            ActionTile(title: "Re-read iPhone", symbol: "arrow.clockwise", tint: .teal) { manager.refresh() }
            ActionTile(title: "Show Log", symbol: "doc.text", tint: .gray, action: showLog)
        }
        .disabled(manager.running)
    }
}

struct ActionTile: View {
    let title: String, symbol: String, tint: Color
    var subtitle: String? = nil
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(tint).frame(height: 28)
                Text(title).font(.callout)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            .frame(maxWidth: .infinity).frame(height: 84)
            .background(hovering ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Photos pane: filter list, grid, Image Capture-style bottom bar

struct PhotosPane: View {
    @EnvironmentObject var manager: DeviceManager
    @Binding var filter: Filter?
    @Binding var thumbSize: Double
    @Binding var byDate: Bool
    @Binding var skipExisting: Bool
    @Binding var deleteAfterCopy: Bool
    let destURL: URL?
    let chooseFolder: () -> Void, showLog: () -> Void, start: () -> Void

    private func count(_ f: Filter) -> Int {
        switch f {
        case .all: return manager.items.count
        case .photos: return manager.photoCount
        case .videos: return manager.videoCount
        case .live: return manager.liveCount
        }
    }

    private var shown: [MediaItem] {
        let list: [MediaItem]
        switch filter ?? .all {
        case .all: list = manager.items
        case .photos: list = manager.items.filter { !$0.isVideo }
        case .videos: list = manager.items.filter { $0.isVideo }
        case .live: list = manager.items.filter { $0.isLivePhoto }
        }
        return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $filter) {
                Section("Library") {
                    ForEach(Filter.allCases) { f in
                        HStack {
                            Label(f.rawValue, systemImage: f.symbol)
                            Spacer()
                            if manager.device != nil {
                                Text(count(f), format: .number).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .tag(f)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)
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
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Slider(value: $thumbSize, in: 80...220).frame(width: 110).help("Thumbnail size")
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
        .frame(height: 38)
    }

    private var grid: some View {
        Group {
            if manager.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: manager.locked ? "lock.iphone" : "iphone.and.arrow.forward")
                        .font(.system(size: 52, weight: .light)).foregroundStyle(.tertiary)
                    Text(manager.statusText).foregroundStyle(.secondary)
                    if manager.device != nil && !manager.catalogComplete && !manager.locked { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize), spacing: 4)], spacing: 4) {
                        ForEach(shown) { item in
                            ThumbCell(item: item, size: thumbSize, selected: manager.selection.contains(item.id))
                                .onTapGesture {
                                    guard !manager.running else { return }
                                    if manager.selection.contains(item.id) { manager.selection.remove(item.id) }
                                    else { manager.selection.insert(item.id) }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if manager.running {
                ProgressView(value: manager.progress.fraction).frame(maxWidth: 320)
                Text(progressText).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer()
                Button("Stop") { manager.cancel() }
            } else {
                Text("Import to:").foregroundStyle(.secondary)
                Button(action: chooseFolder) {
                    Label(destURL?.lastPathComponent ?? "Choose Folder…", systemImage: "folder")
                }
                if let url = destURL, let free = DeviceManager.freeSpace(at: url) {
                    Text("\(DeviceManager.gb(free)) free").font(.callout).foregroundStyle(.secondary)
                }
                if let summary = manager.summary {
                    Divider().frame(height: 16)
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let url = destURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                    }
                }
                Spacer()
                Toggle("Delete after import", isOn: $deleteAfterCopy)
                Button(action: start) {
                    Text(copyButtonTitle).frame(minWidth: 120)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(deleteAfterCopy ? .red : .accentColor)
                .disabled(manager.device == nil || !manager.catalogComplete || manager.selection.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.bar)
    }

    private var copyButtonTitle: String {
        let n = manager.selection.count
        let items = n == 1 ? "Item" : "Items"
        return deleteAfterCopy ? "Move \(n.formatted()) \(items)" : "Copy \(n.formatted()) \(items)"
    }

    private var progressText: String {
        let p = manager.progress
        return "\(p.phase) \(p.done) of \(p.total) · \(DeviceManager.gb(p.bytesDone)) of \(DeviceManager.gb(p.bytesTotal))"
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
                    Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                }
            }
            .frame(width: size, height: size).clipped()

            VStack {
                HStack {
                    if item.isLivePhoto {
                        Label("LIVE", systemImage: "livephoto").labelStyle(.titleAndIcon)
                            .font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
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
                        Text(Self.clock(item.duration)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 2)
                    }
                    statusBadge
                }
            }
            .padding(5)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
        .opacity(item.status == .deleted ? 0.3 : 1)
        .onHover { hovering = $0 }
        .help(item.name)
        .onAppear { if item.thumbnail == nil { item.file.requestThumbnail() } }
    }

    @ViewBuilder private var statusBadge: some View {
        switch item.status {
        case .pending: EmptyView()
        case .copying: ProgressView().controlSize(.mini)
        case .verified, .alreadyCopied:
            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .green)
        case .deleted:
            Image(systemName: "trash.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).shadow(radius: 1)
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
