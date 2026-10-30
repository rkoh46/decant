import SwiftUI
import ImageCaptureCore

@main
struct OffloadApp: App {
    @StateObject private var manager = DeviceManager()

    var body: some Scene {
        WindowGroup("Offload") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Window("Log", id: "log") {
            LogView().environmentObject(manager)
        }
        .defaultSize(width: 560, height: 360)
    }
}

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

struct ContentView: View {
    @EnvironmentObject var manager: DeviceManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("destination") private var destination = ""
    @AppStorage("byDate") private var byDate = true
    @AppStorage("skipExisting") private var skipExisting = true
    @AppStorage("deleteAfterCopy") private var deleteAfterCopy = false
    @AppStorage("thumbSize") private var thumbSize = 132.0
    @State private var filter: Filter? = .all
    @State private var confirmDelete = false
    @State private var spaceWarning: String?

    private var destURL: URL? { destination.isEmpty ? nil : URL(fileURLWithPath: destination) }

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
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                grid
                Divider()
                bottomBar
            }
            .navigationTitle("Offload")
            .navigationSubtitle(manager.device?.name ?? "")
            .toolbar { toolbarItems }
        }
        .alert("Delete from iPhone?", isPresented: $confirmDelete) {
            Button("Copy and Delete", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(manager.selection.count) items will be removed from the iPhone after each copy is verified. The iPhone may keep them in Recently Deleted for 30 days.")
        }
        .alert("Not enough space", isPresented: Binding(get: { spaceWarning != nil }, set: { if !$0 { spaceWarning = nil } })) {
            Button("OK") {}
        } message: { Text(spaceWarning ?? "") }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                deviceRow
            }
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
    }

    private var deviceRow: some View {
        HStack(spacing: 10) {
            if let icon = manager.device?.icon {
                Image(decorative: icon, scale: 1).resizable().frame(width: 36, height: 36)
            } else {
                Image(systemName: "iphone").font(.system(size: 28)).frame(width: 36, height: 36).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.device?.name ?? "No iPhone").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }

    private var subtitle: String {
        guard manager.device != nil else { return "Connect over USB" }
        if manager.catalogComplete {
            var s = DeviceManager.gb(manager.totalBytes)
            if let d = manager.device, d.batteryLevelAvailable { s += " · \(d.batteryLevel)% battery" }
            return s
        }
        return manager.statusText
    }

    private var statusColor: Color {
        if manager.device == nil { return .gray }
        if manager.locked { return .orange }
        return manager.catalogComplete ? .green : .yellow
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Slider(value: $thumbSize, in: 80...220).frame(width: 110).help("Thumbnail size")
            Button("Select All") { manager.selection.formUnion(shown.map { $0.id }) }
                .disabled(manager.running || shown.isEmpty)
            Button("Select None") { manager.selection.subtract(shown.map { $0.id }) }
                .disabled(manager.running || manager.selection.isEmpty)
            Menu {
                Toggle("Sort into Year/Month Folders", isOn: $byDate)
                Toggle("Skip Files Already in Destination", isOn: $skipExisting)
                Divider()
                Button("Re-read iPhone") { manager.refresh() }.disabled(manager.device == nil || manager.running)
                Button("Show Log") { openWindow(id: "log") }
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        Group {
            if manager.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: manager.locked ? "lock.iphone" : "iphone.and.arrow.forward")
                        .font(.system(size: 52, weight: .light)).foregroundStyle(.tertiary)
                    Text(manager.statusText).foregroundStyle(.secondary)
                    if manager.device != nil && !manager.catalogComplete && !manager.locked {
                        ProgressView().controlSize(.small)
                    }
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

    // MARK: Bottom bar (Image Capture style)

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if manager.running {
                ProgressView(value: manager.progress.fraction).frame(maxWidth: 320)
                Text(progressText).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer()
                Button("Stop") { manager.cancel() }
            } else {
                Text("Import to:").foregroundStyle(.secondary)
                Menu {
                    if let url = destURL {
                        Button(url.lastPathComponent) {}
                        Divider()
                    }
                    Button("Choose Folder…", action: chooseFolder)
                } label: {
                    Label(destURL?.lastPathComponent ?? "Choose Folder…", systemImage: "folder")
                }
                .menuStyle(.borderedButton).fixedSize()
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
                Button {
                    guard preflight() else { return }
                    if deleteAfterCopy { confirmDelete = true } else { start() }
                } label: {
                    Text(copyButtonTitle).frame(minWidth: 120)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(deleteAfterCopy ? .red : .accentColor)
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.bar)
    }

    private var copyButtonTitle: String {
        let n = manager.selection.count
        let items = n == 1 ? "Item" : "Items"
        return deleteAfterCopy ? "Move \(n) \(items)" : "Copy \(n) \(items)"
    }

    private var progressText: String {
        let p = manager.progress
        return "\(p.phase) \(p.done) of \(p.total) · \(DeviceManager.gb(p.bytesDone)) of \(DeviceManager.gb(p.bytesTotal))"
    }

    // MARK: Actions

    private var canStart: Bool {
        manager.device != nil && manager.catalogComplete && !manager.running && !manager.selection.isEmpty && destURL != nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if let url = destURL { panel.directoryURL = url }
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    private func preflight() -> Bool {
        guard let url = destURL else { return false }
        if let free = DeviceManager.freeSpace(at: url), free < manager.selectedBytes {
            spaceWarning = "The selection is \(DeviceManager.gb(manager.selectedBytes)) but only \(DeviceManager.gb(free)) is free in \(url.lastPathComponent)."
            return false
        }
        return true
    }

    private func start() {
        guard let url = destURL else { return }
        manager.offload(OffloadOptions(destination: url, byDate: byDate, skipExisting: skipExisting, deleteAfterCopy: deleteAfterCopy))
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

            // Corner badges
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
