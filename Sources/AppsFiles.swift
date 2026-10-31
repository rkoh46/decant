import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apps (ideviceinstaller)

struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let version: String
    let staticSize: Int
    let dynamicSize: Int
    let fileSharing: Bool
    let system: Bool
    var developer = ""
    var purchased: Date?        // App Store purchase date from iTunesMetadata; iOS does not expose the install date over USB
    var id: String { bundleID }
    var totalSize: Int { staticSize + dynamicSize }
}

@MainActor
final class AppsService: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var running = false
    @Published var phase = ""
    @Published var progress: Double?
    var log: (String) -> Void = { _ in }

    private static func list(udid: String, includeSystem: Bool, attributes: [String]) async -> [[String: Any]]? {
        var args = ["-u", udid, "list", includeSystem ? "--all" : "--user", "--xml"]
        for a in attributes { args += ["-a", a] }
        guard let data = await Task.detached(priority: .userInitiated, operation: { Lockdown.run("ideviceinstaller", args) }).value else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]]
    }

    /// Names first (instant), then sizes (the phone takes ~20 s to measure them) and icons in the background.
    func load(udid: String, includeSystem: Bool) async {
        if Demo.on { apps = Demo.apps().sorted { $0.totalSize > $1.totalSize }; icons = Demo.icons(); return }
        loading = true
        defer { loading = false }
        guard let list = await Self.list(udid: udid, includeSystem: includeSystem,
                                         attributes: ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString",
                                                      "CFBundleVersion", "ApplicationType", "UIFileSharingEnabled", "iTunesMetadata"]) else {
            log("Could not read the app list"); return
        }
        var sizes: [String: (Int, Int)] = [:]
        for a in apps { sizes[a.bundleID] = (a.staticSize, a.dynamicSize) }
        apps = list.compactMap { d in
            guard let id = d["CFBundleIdentifier"] as? String else { return nil }
            var app = InstalledApp(bundleID: id,
                                   name: d["CFBundleDisplayName"] as? String ?? d["CFBundleName"] as? String ?? id,
                                   version: d["CFBundleShortVersionString"] as? String ?? d["CFBundleVersion"] as? String ?? "",
                                   staticSize: sizes[id]?.0 ?? 0,
                                   dynamicSize: sizes[id]?.1 ?? 0,
                                   fileSharing: d["UIFileSharingEnabled"] as? Bool ?? false,
                                   system: (d["ApplicationType"] as? String) == "System")
            if let meta = d["iTunesMetadata"] as? Data,
               let m = (try? PropertyListSerialization.propertyList(from: meta, format: nil)) as? [String: Any] {
                app.developer = m["artistName"] as? String ?? ""
                if let info = m["com.apple.iTunesStore.downloadInfo"] as? [String: Any], let ds = info["purchaseDate"] as? String {
                    app.purchased = ISO8601DateFormatter().date(from: ds)
                }
            }
            return app
        }
        .sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loading = false
        async let icons: () = loadIcons(udid: udid)
        measuring = true
        if let sized = await Self.list(udid: udid, includeSystem: includeSystem, attributes: ["CFBundleIdentifier", "StaticDiskUsage", "DynamicDiskUsage"]) {
            var m: [String: (Int, Int)] = [:]
            for d in sized { if let id = d["CFBundleIdentifier"] as? String { m[id] = (d["StaticDiskUsage"] as? Int ?? 0, d["DynamicDiskUsage"] as? Int ?? 0) } }
            apps = apps.map { a in
                guard let s = m[a.bundleID] else { return a }
                var b = InstalledApp(bundleID: a.bundleID, name: a.name, version: a.version, staticSize: s.0, dynamicSize: s.1, fileSharing: a.fileSharing, system: a.system)
                b.developer = a.developer; b.purchased = a.purchased
                return b
            }
            .sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        measuring = false
        await icons
    }

    @Published var measuring = false
    @Published var icons: [String: NSImage] = [:]
    static let iconDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Decant/AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Icons come from the phone's SpringBoard service (decant-icon), 24 apps per call, cached on disk per bundle id.
    func loadIcons(udid: String) async {
        var missing: [InstalledApp] = []
        for app in apps where icons[app.bundleID] == nil {
            let file = Self.iconDir.appendingPathComponent(app.bundleID + ".png")
            if let img = NSImage(contentsOf: file) { icons[app.bundleID] = img } else { missing.append(app) }
        }
        guard !missing.isEmpty, Tools.has("decant-icon") else { return }
        for chunk in stride(from: 0, to: missing.count, by: 24).map({ Array(missing[$0..<min($0 + 24, missing.count)]) }) {
            var args = ["-u", udid]
            for a in chunk { args += [a.bundleID, Self.iconDir.appendingPathComponent(a.bundleID + ".png").path] }
            _ = await Task.detached(priority: .utility, operation: { Lockdown.run("decant-icon", args) }).value
            for a in chunk {
                if let img = NSImage(contentsOf: Self.iconDir.appendingPathComponent(a.bundleID + ".png")) { icons[a.bundleID] = img }
            }
        }
    }

    func uninstall(_ app: InstalledApp, udid: String) async {
        guard !running else { return }
        running = true; phase = "Uninstalling \(app.name)"; progress = nil
        log(phase)
        let status = await Tools.stream("ideviceinstaller", ["-u", udid, "uninstall", app.bundleID]) { [weak self] l in
            if let p = Tools.percent(in: l) { self?.progress = p } else if l.contains("Complete") || l.contains("ERROR") { self?.log(l) }
        }
        phase = status == 0 ? "Uninstalled \(app.name)" : "Could not uninstall \(app.name)"
        log(phase)
        running = false
        if status == 0 { apps.removeAll { $0.bundleID == app.bundleID } }
    }

    /// Install a signed .ipa. The phone checks the signature itself; unsigned or wrongly signed packages fail here.
    func install(_ ipa: URL, udid: String) async {
        guard !running else { return }
        running = true; phase = "Installing \(ipa.lastPathComponent)"; progress = 0
        log(phase)
        var lastError = ""
        let status = await Tools.stream("ideviceinstaller", ["-u", udid, "install", ipa.path]) { [weak self] l in
            if let p = Tools.percent(in: l) { self?.progress = p }
            if l.contains("ERROR") || l.contains("Error") { lastError = l; self?.log(l) }
        }
        phase = status == 0 ? "Installed \(ipa.lastPathComponent)" : "Install failed: \(lastError.isEmpty ? "the phone refused the package" : lastError)"
        log(phase)
        running = false
        await load(udid: udid, includeSystem: false)
    }
}

struct AppsPane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var apps: AppsService
    @State private var search = ""
    @State private var includeSystem = false
    @AppStorage("appsSort") private var sort = "size"
    @State private var uninstalling: InstalledApp?
    @State private var dropTargeted = false
    let openFiles: (InstalledApp) -> Void

    private var udid: String { Lockdown.cachedUDID ?? "" }
    private var ready: Bool { manager.device != nil && Lockdown.available && !udid.isEmpty && Tools.has("ideviceinstaller") }

    private var shown: [InstalledApp] {
        let list = search.isEmpty ? apps.apps : apps.apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
        switch sort {
        case "name": return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "date": return list.sorted { ($0.purchased ?? .distantPast) != ($1.purchased ?? .distantPast) ? ($0.purchased ?? .distantPast) > ($1.purchased ?? .distantPast) : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "data": return list.sorted { $0.dynamicSize != $1.dynamicSize ? $0.dynamicSize > $1.dynamicSize : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        default: return list
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search apps", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                Picker("Sort", selection: $sort) {
                    Text("Size").tag("size"); Text("Data").tag("data"); Text("Name").tag("name"); Text("Added").tag("date")
                }
                .pickerStyle(.segmented).frame(width: 240).labelsHidden()
                .help("Added is the App Store purchase date; iOS does not report the install date")
                Toggle("Include system apps", isOn: $includeSystem).toggleStyle(.checkbox)
                    .onChange(of: includeSystem) { _ in Task { await apps.load(udid: udid, includeSystem: includeSystem) } }
                Spacer()
                Text(apps.measuring ? "\(shown.count.formatted()) apps · measuring sizes…" : "\(shown.count.formatted()) apps · \(DeviceManager.gb(shown.reduce(0) { $0 + $1.totalSize }))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button("Install .ipa…", action: chooseIPA).disabled(!ready || apps.running)
                Button { Task { await apps.load(udid: udid, includeSystem: includeSystem) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!ready || apps.loading)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            if !ready {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text(manager.device == nil ? manager.statusText : "This build is missing the app service").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.loading && apps.apps.isEmpty {
                ProgressView("Reading apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { app in
                    HStack(spacing: 12) {
                        Group {
                            if let img = apps.icons[app.bundleID] {
                                Image(nsImage: img).resizable().interpolation(.high).frame(width: 32, height: 32)
                            } else {
                                RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.15)).frame(width: 32, height: 32)
                                    .overlay(Image(systemName: app.system ? "gearshape" : "app").foregroundStyle(.secondary))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.system(size: 13, weight: .medium))
                            Text([app.developer.isEmpty ? app.bundleID : app.developer, app.version,
                                  app.purchased.map { "added " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? ""]
                                 .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                .help(app.bundleID)
                        }
                        Spacer()
                        if app.totalSize > 0 {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(DeviceManager.gb(app.totalSize)).font(.system(size: 13)).monospacedDigit()
                                Text("app \(DeviceManager.gb(app.staticSize)) · data \(DeviceManager.gb(app.dynamicSize))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        } else if apps.measuring {
                            Text("…").foregroundStyle(.tertiary)
                        }
                        if app.fileSharing {
                            Button("Files") { openFiles(app) }.controlSize(.small).help("Browse this app's documents")
                        }
                        Button("Uninstall…") { uninstalling = app }.controlSize(.small).disabled(app.system || apps.running)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
            if apps.running {
                Divider()
                HStack(spacing: 12) {
                    ProgressView(value: apps.progress ?? 0).frame(maxWidth: 320).opacity(apps.progress == nil ? 0 : 1)
                        .overlay { if apps.progress == nil { ProgressView().controlSize(.small) } }
                    Text(apps.phase).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 52).background(.bar)
            } else if !apps.phase.isEmpty {
                Divider()
                HStack { Text(apps.phase).font(.callout).foregroundStyle(.secondary); Spacer() }
                    .padding(.horizontal, 16).frame(height: 40).background(.bar)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(8)
                    .overlay(Text("Drop an .ipa to install it").font(.headline))
                    .background(Color.accentColor.opacity(0.06))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard ready else { return false }
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.pathExtension.lowercased() == "ipa" {
                        Task { @MainActor in await apps.install(url, udid: udid) }
                    }
                }
            }
            return true
        }
        .onAppear {
            apps.log = { [weak manager] in manager?.addLog($0) }
            if ready && apps.apps.isEmpty { Task { await apps.load(udid: udid, includeSystem: includeSystem) } }
        }
        .onChange(of: manager.catalogComplete) { ok in if ok && ready && apps.apps.isEmpty { Task { await apps.load(udid: udid, includeSystem: includeSystem) } } }
        .alert("Uninstall \(uninstalling?.name ?? "")?", isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })) {
            Button("Uninstall", role: .destructive) { if let a = uninstalling { Task { await apps.uninstall(a, udid: udid) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app and its data (\(DeviceManager.gb(uninstalling?.dynamicSize ?? 0))) are removed from the iPhone. Purchases can be downloaded again from the App Store.")
        }
    }

    private func chooseIPA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.canChooseDirectories = false
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await apps.install(url, udid: udid) }
    }
}

// MARK: - Files (afcclient)

struct RemoteEntry: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: Int
    let modified: Date?
    var id: String { name }
}

enum FileRoot: Hashable {
    case media
    case ringtones                      // its own pane: the tones list, not a folder listing
    case appDocuments(String, String)   // bundle id, display name
    var title: String {
        switch self {
        case .media: return "Media"
        case .ringtones: return "Ringtones"
        case .appDocuments(_, let name): return name
        }
    }
}

@MainActor
final class FilesService: ObservableObject {
    @Published var entries: [RemoteEntry] = []
    @Published var path = "/"
    @Published var root: FileRoot = .media
    @Published var loading = false
    @Published var running = false
    @Published var phase = ""
    var log: (String) -> Void = { _ in }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd MMM yyyy HH:mm:ss"; return f
    }()

    /// house_arrest exposes the app container; its Documents folder is the part the user may touch.
    var homePath: String { if case .appDocuments = root { return "/Documents" } else { return "/" } }

    private func baseArgs(_ udid: String) -> [String] {
        var a = ["-u", udid]
        if case .appDocuments(let bundle, _) = root { a += ["--documents", bundle] }
        return a
    }

    /// afcclient is interactive: commands go in on stdin, the coloured prompt is stripped from what comes out.
    private func run(_ commands: [String], udid: String) async -> [String] {
        var lines: [String] = []
        await Tools.stream("afcclient", baseArgs(udid), input: commands.joined(separator: "\n") + "\nquit\n") { l in
            var s = l.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            if let r = s.range(of: #"^afc:[^>]*> "#, options: .regularExpression) { s.removeSubrange(r) }
            if !s.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(s) }
        }
        return lines
    }

    func list(udid: String) async {
        if Demo.on { entries = Demo.files(root: root, path: path); return }
        loading = true
        defer { loading = false }
        let out = await run(["ls -l \(quote(path))"], udid: udid)
        if let err = out.first(where: { $0.hasPrefix("Error") || $0.hasPrefix("ERROR") }) { log("\(root.title)\(path): \(err)"); entries = []; return }
        entries = out.compactMap { line in
            // -rw-r--r--    1 mobile mobile    3020295 03 Oct 2023 13:48:32 IMG_0911.HEIC
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9, parts[0].count >= 10 else { return nil }
            let date = Self.dateFormatter.date(from: "\(parts[5]) \(parts[6]) \(parts[7]) \(parts[8].split(separator: " ").first ?? "")")
            let nameStart = parts[8].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let name = nameStart.count > 1 ? String(nameStart[1]) : ""
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            return RemoteEntry(name: name, isDirectory: parts[0].hasPrefix("d"), size: Int(parts[4]) ?? 0, modified: date)
        }
        .sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    func open(_ entry: RemoteEntry, udid: String) async {
        guard entry.isDirectory else { return }
        path = (path as NSString).appendingPathComponent(entry.name)
        await list(udid: udid)
    }

    func up(udid: String) async {
        guard path != homePath else { return }
        path = (path as NSString).deletingLastPathComponent
        if path.isEmpty || path.count < homePath.count { path = homePath }
        await list(udid: udid)
    }

    func download(_ entries: [RemoteEntry], to dir: URL, udid: String) async {
        running = true; phase = "Downloading \(entries.count) item\(entries.count == 1 ? "" : "s")"
        for e in entries {
            let remote = (path as NSString).appendingPathComponent(e.name)
            let out = await run(["get \(e.isDirectory ? "-r " : "")\(quote(remote)) \(quote(dir.appendingPathComponent(e.name).path))"], udid: udid)
            if let err = out.first(where: { $0.hasPrefix("Error") || $0.hasPrefix("ERROR") }) { log("\(e.name): \(err)") }
        }
        phase = "Downloaded to \(dir.lastPathComponent)"
        log("Downloaded \(entries.count) items from \(root.title)\(path) to \(dir.path)")
        running = false
    }

    func upload(_ files: [URL], udid: String) async {
        running = true; phase = "Uploading \(files.count) item\(files.count == 1 ? "" : "s")"
        for f in files {
            let remote = (path as NSString).appendingPathComponent(f.lastPathComponent)
            let out = await run(["put -r \(quote(f.path)) \(quote(remote))"], udid: udid)
            if let err = out.first(where: { $0.hasPrefix("Error") || $0.hasPrefix("ERROR") }) { log("\(f.lastPathComponent): \(err)") }
        }
        phase = "Uploaded"
        log("Uploaded \(files.count) items to \(root.title)\(path)")
        running = false
        await list(udid: udid)
    }

    func delete(_ entries: [RemoteEntry], udid: String) async {
        running = true; phase = "Deleting"
        for e in entries {
            let out = await run(["rm \(quote((path as NSString).appendingPathComponent(e.name)))"], udid: udid)
            if let err = out.first(where: { $0.hasPrefix("Error") || $0.hasPrefix("ERROR") }) { log("\(e.name): \(err)") }
        }
        log("Deleted \(entries.count) items in \(root.title)\(path)")
        running = false
        await list(udid: udid)
    }

    func makeFolder(_ name: String, udid: String) async {
        _ = await run(["mkdir \(quote((path as NSString).appendingPathComponent(name)))"], udid: udid)
        await list(udid: udid)
    }

    private func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}

struct FilesPane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var files: FilesService
    @EnvironmentObject var apps: AppsService
    @State private var selection = Set<String>()
    @State private var confirmDelete = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var dropTargeted = false

    private var udid: String { Lockdown.cachedUDID ?? "" }
    private var ready: Bool { manager.device != nil && Lockdown.available && !udid.isEmpty && Tools.has("afcclient") }
    private var selected: [RemoteEntry] { files.entries.filter { selection.contains($0.id) } }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { files.root }, set: { r in files.root = r; files.path = files.homePath; selection = []; Task { await files.list(udid: udid) } })) {
                Section("Locations") {
                    Label("Media", systemImage: "iphone").tag(FileRoot.media)
                    Label("Ringtones", systemImage: "bell").tag(FileRoot.ringtones)
                }
                Section("App documents") {
                    ForEach(apps.apps.filter { $0.fileSharing }) { app in
                        Label(app.name, systemImage: "folder").tag(FileRoot.appDocuments(app.bundleID, app.name))
                    }
                    if apps.apps.filter({ $0.fileSharing }).isEmpty {
                        Text("Apps that share files appear here").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            Divider()
            if case .ringtones = files.root {
                RingtonesPane().environmentObject(manager)
            } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { Task { await files.up(udid: udid) } } label: { Image(systemName: "chevron.left") }.disabled(files.path == files.homePath || files.loading)
                    Text("\(files.root.title)\(files.path == files.homePath ? "" : String(files.path.dropFirst(files.homePath == "/" ? 0 : files.homePath.count)))").font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if files.loading { ProgressView().controlSize(.mini) }
                    Spacer()
                    Text("\(files.entries.count) items").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Button("New Folder") { folderName = ""; newFolder = true }.disabled(!ready || files.running)
                    Button("Upload…", action: chooseUploads).disabled(!ready || files.running)
                    Button("Download…", action: chooseDownload).disabled(selected.isEmpty || files.running)
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(selected.isEmpty || files.running)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .frame(height: 40)
                Divider()
                if !ready {
                    VStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                        Text(manager.device == nil ? manager.statusText : "This build is missing the file service").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(files.entries, selection: $selection) {
                        TableColumn("Name") { e in
                            HStack(spacing: 8) {
                                Image(systemName: e.isDirectory ? "folder.fill" : icon(for: e.name)).foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                                Text(e.name)
                            }
                        }
                        TableColumn("Size") { e in Text(e.isDirectory ? "–" : DeviceManager.gb(e.size)).foregroundStyle(.secondary).monospacedDigit() }.width(90)
                        TableColumn("Modified") { e in Text(e.modified?.formatted(date: .abbreviated, time: .shortened) ?? "–").foregroundStyle(.secondary) }.width(170)
                    }
                    .overlay {
                        if files.entries.isEmpty && !files.loading {
                            Text("Empty folder").foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if ids.count == 1, let e = files.entries.first(where: { $0.id == ids.first! }), e.isDirectory {
                            Button("Open") { Task { await files.open(e, udid: udid) } }
                        }
                        Button("Download…") { selection = ids; chooseDownload() }
                        Button("Delete…", role: .destructive) { selection = ids; confirmDelete = true }
                    } primaryAction: { ids in
                        if ids.count == 1, let e = files.entries.first(where: { $0.id == ids.first! }), e.isDirectory {
                            selection = []
                            Task { await files.open(e, udid: udid) }
                        }
                    }
                }
                if case .media = files.root {
                    Divider()
                    Text("Media is what the iPhone shows over USB: books, ringtones, recordings and the Photos database. The Files app's On My iPhone and iCloud Drive folders are not reachable this way; an app's own documents are listed on the left when the app allows file sharing.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                if files.running || !files.phase.isEmpty {
                    Divider()
                    HStack(spacing: 12) {
                        if files.running { ProgressView().controlSize(.small) }
                        Text(files.phase).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).frame(height: 40).background(.bar)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(8)
                        .overlay(Text("Drop files to upload them here").font(.headline))
                        .background(Color.accentColor.opacity(0.06))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard ready else { return false }
                var urls: [URL] = []
                let group = DispatchGroup()
                for p in providers {
                    group.enter()
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { Task { await files.upload(urls, udid: udid) } }
                return true
            }
            }
        }
        .onAppear {
            files.log = { [weak manager] in manager?.addLog($0) }
            if ProcessInfo.processInfo.environment["DECANT_FILES"] == "ringtones" { files.root = .ringtones }   // screenshot aid
            loadIfNeeded()
        }
        .onChange(of: manager.catalogComplete) { _ in loadIfNeeded() }
        .alert("Delete \(selected.count) item\(selected.count == 1 ? "" : "s") from the iPhone?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { let s = selected; selection = []; Task { await files.delete(s, udid: udid) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Files deleted here are gone; there is no Recently Deleted for them.") }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { Task { await files.makeFolder(folderName, udid: udid) } }.disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func loadIfNeeded() {
        guard ready else { return }
        if files.entries.isEmpty && !files.loading { files.path = files.homePath; Task { await files.list(udid: udid) } }
        if apps.apps.isEmpty && !apps.loading { Task { await apps.load(udid: udid, includeSystem: false) } }
    }

    /// Open a specific app's documents (from the Apps tab).
    func show(app: InstalledApp) {
        files.root = .appDocuments(app.bundleID, app.name); files.path = files.homePath; selection = []
        Task { await files.list(udid: udid) }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "heic", "jpg", "jpeg", "png", "gif", "webp": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "aac", "wav", "caf": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "ipa": return "doc.zipper"
        default: return "doc"
        }
    }

    private func chooseDownload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Download here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let s = selected
        Task { await files.download(s, to: dir, udid: udid) }
    }

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await files.upload(urls, udid: udid) }
    }
}
