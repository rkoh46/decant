import SwiftUI
import ImageCaptureCore

// MARK: - Tools: a toolbox of real device actions, grouped, one tile each

struct ToolsPane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var firmware: FirmwareService
    @Environment(\.openWindow) private var openWindow
    @State private var confirmRestart = false
    @State private var confirmShutDown = false
    @State private var confirmRecovery = false
    @State private var confirmUnpair = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var showIdentifiers = false
    @State private var notice: String?
    let showLog: () -> Void

    private var ready: Bool { manager.device != nil && Lockdown.available && !manager.running && !manager.locked }
    private let columns = [GridItem(.adaptive(minimum: 208, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("Power") {
                    ToolTile("Restart", "arrow.counterclockwise", "Reboots the iPhone; it reconnects by itself", enabled: ready) { confirmRestart = true }
                    ToolTile("Shut Down", "power", "Turns the iPhone off until its side button is pressed", enabled: ready) { confirmShutDown = true }
                    ToolTile("Enter Recovery", "arrow.down.to.line", "Puts the iPhone in recovery mode for a restore", enabled: ready && Tools.has("ideviceenterrecovery")) { confirmRecovery = true }
                    ToolTile("Exit Recovery", "arrow.up.to.line", "Boots an iPhone that is sitting in recovery mode", enabled: Tools.has("irecovery") && !manager.running) {
                        Task { await firmware.exitRecovery() }
                    }
                }
                section("Device") {
                    ToolTile("Rename", "pencil", "The name shown in Finder, AirDrop and on the phone", enabled: ready) { newName = manager.device?.name ?? ""; renaming = true }
                    ToolTile("Identifiers", "number", "IMEI, MEID, Wi‑Fi and Bluetooth addresses, serial, UDID, ECID", enabled: manager.info != nil) { showIdentifiers = true }
                    ToolTile("Export Device Report", "doc.badge.arrow.up", "Every value the phone reports about itself, as a file", enabled: ready) { manager.exportReport() }
                    ToolTile("Unpair This Mac", "link.badge.plus", "Removes this Mac's trust; the phone asks to trust again", enabled: ready && Tools.has("idevicepair")) { confirmUnpair = true }
                }
                section("Diagnostics") {
                    ToolTile("Crash Reports", "exclamationmark.triangle", "Copies the phone's crash logs into a folder", enabled: ready && Tools.has("idevicecrashreport")) { manager.exportCrashReports() }
                    ToolTile("System Log", "text.alignleft", "Live log from the phone, with a filter", enabled: ready && Tools.has("idevicesyslog")) { openWindow(id: "syslog") }
                    ToolTile("Screenshot", "camera.viewfinder", "Saves the phone's screen to Pictures (Developer Mode needed)", enabled: ready && Tools.has("idevicescreenshot")) { manager.screenshot() }
                    ToolTile("Battery", "battery.75percent", manager.battery.map { b in
                        "\(b.level.map { "\($0)%" } ?? "–")" + (b.health.map { String(format: " · %.0f%% health", $0) } ?? "") + (b.cycleCount.map { " · \($0.formatted()) cycles" } ?? "")
                    } ?? "Level, health and cycle count", enabled: manager.battery != nil, info: true) {}
                }
                section("Decant") {
                    ToolTile("Show Log", "doc.text", "Everything Decant did this session, with times", enabled: true, action: showLog)
                    ToolTile("Re-read Library", "arrow.clockwise", "Reads the camera roll again without reconnecting", enabled: manager.device != nil && !manager.running) { manager.refresh() }
                }
                if manager.device != nil && !Lockdown.available {
                    Text("Most tools need the device services that ship inside Decant; this build is missing them").font(.caption).foregroundStyle(.secondary)
                }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Restart the iPhone?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { manager.restart() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Shut down the iPhone?", isPresented: $confirmShutDown) {
            Button("Shut Down", role: .destructive) { manager.shutDown() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You will need to press its side button to turn it on again.") }
        .alert("Put the iPhone in recovery mode?", isPresented: $confirmRecovery) {
            Button("Enter Recovery", role: .destructive) { Task { if let u = Lockdown.firstUDID() { await firmware.enterRecovery(udid: u) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The screen shows the restore symbol. Exit Recovery brings it back without changing anything.") }
        .alert("Unpair this Mac from the iPhone?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { manager.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The phone will ask whether to trust this Mac the next time it is connected.") }
        .alert("Rename iPhone", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { manager.rename(newName.trimmingCharacters(in: .whitespaces)) }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showIdentifiers) { IdentifiersSheet().environmentObject(manager) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ tiles: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12, content: tiles)
        }
    }
}

struct ToolTile: View {
    let title: String, symbol: String, detail: String, enabled: Bool, info: Bool, action: () -> Void
    @State private var hovering = false

    init(_ title: String, _ symbol: String, _ detail: String, enabled: Bool, info: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.detail = detail; self.enabled = enabled; self.info = info; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary).frame(height: 24)
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .padding(16)
            .background(Color(nsColor: hovering && enabled ? .selectedContentBackgroundColor : .controlBackgroundColor).opacity(hovering && enabled ? 0.18 : 1),
                        in: RoundedRectangle(cornerRadius: 10))
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || info)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 && !info }
    }
}

// MARK: - Identifiers sheet: masked by default, each copyable

struct IdentifiersSheet: View {
    @EnvironmentObject var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false

    private var rows: [(String, String)] {
        guard let i = manager.info else { return [] }
        return [("Serial number", i.serial), ("UDID", i.udid), ("ECID", i.ecid), ("IMEI", i.imei), ("IMEI 2", i.imei2),
                ("MEID", i.meid), ("Wi‑Fi address", i.wifiAddress), ("Bluetooth address", i.bluetoothAddress),
                ("Model", i.model), ("Model number", i.modelNumber + i.region), ("Baseband serial", i.basebandSerial)]
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Identifiers").font(.system(size: 15, weight: .medium))
                Spacer()
                Toggle("Reveal", isOn: $revealed).toggleStyle(.switch).controlSize(.small)
            }
            .padding(16)
            Divider()
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(spacing: 12) {
                        Text(label).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                        Text(revealed ? value : String(repeating: "•", count: min(value.count, 24))).monospaced().textSelection(.enabled)
                        Spacer()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless).help("Copy")
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 16).frame(height: 36)
                    .overlay(alignment: .bottom) { Divider().padding(.leading, 16) }
                }
            }
            Divider()
            HStack {
                Text("Treat these like passwords: they identify this exact phone.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560)
    }
}

// MARK: - System log window

@MainActor
final class SyslogService: ObservableObject {
    @Published var lines: [String] = []
    @Published var running = false
    private var process: Process?

    func start(udid: String) {
        guard !running else { return }
        running = true
        Task {
            await Tools.stream("idevicesyslog", ["-u", udid], register: { [weak self] p in Task { @MainActor in self?.process = p } }) { [weak self] l in
                Task { @MainActor in
                    guard let self else { return }
                    self.lines.append(l)
                    if self.lines.count > 5000 { self.lines.removeFirst(self.lines.count - 5000) }
                }
            }
            await MainActor.run { self.running = false; self.process = nil }
        }
    }

    func stop() { process?.terminate() }
}

struct SyslogView: View {
    @EnvironmentObject var manager: DeviceManager
    @StateObject private var log = SyslogService()
    @State private var filter = ""
    @State private var paused = false

    private var shown: [String] {
        filter.isEmpty ? log.lines : log.lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 240)
                Toggle("Pause", isOn: $paused).toggleStyle(.checkbox)
                Button("Clear") { log.lines = [] }
                Spacer()
                Text("\(shown.count.formatted()) lines").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button(log.running ? "Stop" : "Start") {
                    if log.running { log.stop() } else if let u = Lockdown.firstUDID() { log.start(udid: u) }
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.suffix(2000).enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: shown.count) { n in
                    if !paused, n > 0 { proxy.scrollTo(min(n, 2000) - 1, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { if let u = Lockdown.firstUDID() { log.start(udid: u) } }
        .onDisappear { log.stop() }
    }
}

// MARK: - Device-side actions behind the tiles

extension DeviceManager {
    func unpair() { deviceCommandPublic("idevicepair", ["unpair"], "Unpairing this Mac") }

    func exportReport() {
        guard let udid = Lockdown.firstUDID() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(device?.name ?? "iPhone") device report.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached {
            let data = Lockdown.run("ideviceinfo", ["-u", udid, "-x"])
            await MainActor.run {
                if let data, (try? data.write(to: url)) != nil {
                    self.addLog("Device report saved to \(url.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    self.addLog("Could not read the device report")
                }
            }
        }
    }

    func exportCrashReports() {
        guard let udid = Lockdown.firstUDID() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save crash reports here"
        panel.directoryURL = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("Decant")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        addLog("Copying crash reports to \(dir.path)…")
        Task { @MainActor in
            var count = 0
            let status = await Tools.stream("idevicecrashreport", ["-u", udid, "-e", dir.path]) { l in if l.contains("Copy") || l.hasSuffix(".ips") { count += 1 } }
            addLog(status == 0 ? "Crash reports copied (\(count) files mentioned)" : "Crash report copy failed")
            if status == 0 { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        }
    }

    func screenshot() {
        guard let udid = Lockdown.firstUDID() else { return }
        let dir = (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Decant Screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("\(device?.name ?? "iPhone") \(f.string(from: Date())).png")
        Task { @MainActor in
            var output = ""
            let status = await Tools.stream("idevicescreenshot", ["-u", udid, url.path]) { output += $0 + " " }
            if status == 0, FileManager.default.fileExists(atPath: url.path) {
                addLog("Screenshot saved to \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                addLog("Screenshot failed: \(output.trimmingCharacters(in: .whitespaces)). On iOS 17 and later turn on Developer Mode (Settings → Privacy & Security → Developer Mode).")
            }
        }
    }
}
