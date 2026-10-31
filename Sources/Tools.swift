import SwiftUI
import ImageCaptureCore
import Charts

// MARK: - Tools: a list of tools on the left, the chosen tool with its own content on the right

enum Tool: String, CaseIterable, Identifiable {
    case restart, shutDown, enterRecovery, exitRecovery
    case rename, identifiers, report, unpair
    case crashReports, systemLog, screenshot, battery, diagnostics
    case appLog, reread
    var id: String { rawValue }

    var title: String {
        switch self {
        case .restart: return "Restart"
        case .shutDown: return "Shut Down"
        case .enterRecovery: return "Enter Recovery"
        case .exitRecovery: return "Exit Recovery"
        case .rename: return "Rename"
        case .identifiers: return "Identifiers"
        case .report: return "Device Report"
        case .unpair: return "Unpair This Mac"
        case .crashReports: return "Crash Reports"
        case .systemLog: return "System Log"
        case .screenshot: return "Screenshot"
        case .battery: return "Battery"
        case .diagnostics: return "Diagnostics"
        case .appLog: return "Decant Log"
        case .reread: return "Re-read Library"
        }
    }

    var symbol: String {
        switch self {
        case .restart: return "arrow.counterclockwise"
        case .shutDown: return "power"
        case .enterRecovery: return "arrow.down.to.line"
        case .exitRecovery: return "arrow.up.to.line"
        case .rename: return "pencil"
        case .identifiers: return "number"
        case .report: return "doc.badge.arrow.up"
        case .unpair: return "link.badge.plus"
        case .crashReports: return "exclamationmark.triangle"
        case .systemLog: return "text.alignleft"
        case .screenshot: return "camera.viewfinder"
        case .battery: return "battery.75percent"
        case .diagnostics: return "stethoscope"
        case .appLog: return "doc.text"
        case .reread: return "arrow.clockwise"
        }
    }

    var blurb: String {
        switch self {
        case .restart: return "Reboots the iPhone. It reconnects by itself about a minute later."
        case .shutDown: return "Turns the iPhone off. It stays off until its side button is held."
        case .enterRecovery: return "Puts the iPhone in recovery mode, the state a firmware restore starts from. Nothing is changed by entering it."
        case .exitRecovery: return "Boots an iPhone that is sitting in recovery mode back into iOS."
        case .rename: return "The name the phone shows in Finder, AirDrop, Bluetooth and at the top of Settings."
        case .identifiers: return "The numbers that identify this exact phone. Masked until you reveal them; each one can be copied."
        case .report: return "Every value the phone reports about itself, saved as a property list you can open or send."
        case .unpair: return "Removes this Mac from the phone's trusted computers. The phone asks to trust it again on the next connection."
        case .crashReports: return "Copies the phone's crash logs to a folder on the Mac, for reading or for sending to a developer."
        case .systemLog: return "The phone's live system log, the same stream Console shows, with a filter."
        case .screenshot: return "Captures the phone's screen into your Pictures folder. iOS 17 and later require Developer Mode (Settings → Privacy & Security)."
        case .battery: return "What the phone's battery reports about itself, and how its health and cycle count have moved since Decant first saw it."
        case .diagnostics: return "The phone's own self-tests (battery gauge, storage, Wi-Fi) and what it is drawing from the charger right now."
        case .appLog: return "Everything Decant did in this session, with times."
        case .reread: return "Reads the camera roll again from the open connection, without reconnecting."
        }
    }

    static let sections: [(String, [Tool])] = [
        ("Power", [.restart, .shutDown, .enterRecovery, .exitRecovery]),
        ("Device", [.rename, .identifiers, .report, .unpair]),
        ("Diagnostics", [.battery, .diagnostics, .crashReports, .systemLog, .screenshot]),
        ("Decant", [.appLog, .reread]),
    ]
}

struct ToolsPane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var firmware: FirmwareService
    @State private var selected: Tool? = Tool(rawValue: ProcessInfo.processInfo.environment["DECANT_TOOL"] ?? "") ?? .battery   // screenshot aid
    let showLog: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(Tool.sections, id: \.0) { title, tools in
                    Section(title) {
                        ForEach(tools) { t in Label(t.title, systemImage: t.symbol).tag(t) }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            Divider()
            ScrollView {
                if let tool = selected {
                    ToolDetail(tool: tool)
                        .environmentObject(manager).environmentObject(firmware)
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The selected tool

struct ToolDetail: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var firmware: FirmwareService
    let tool: Tool
    @State private var confirming = false
    @State private var newName = ""
    @State private var revealed = false

    private var ready: Bool { manager.device != nil && Lockdown.available && !manager.running && !manager.locked }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: tool.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary).frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tool.title).font(.system(size: 22, weight: .medium))
                    Text(tool.blurb).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            if manager.device == nil {
                Text(manager.statusText).font(.caption).foregroundStyle(.secondary)
            } else if !Lockdown.available {
                Text("This build is missing the device services, so most tools cannot run").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { newName = manager.device?.name ?? "" }
        .onChange(of: manager.device?.name) { newName = $0 ?? "" }
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .restart:
            destructive("Restart iPhone", confirm: "Restart the iPhone?", message: "It disconnects while rebooting and comes back on its own.") { manager.restart() }
        case .shutDown:
            destructive("Shut Down iPhone", confirm: "Shut down the iPhone?", message: "You will need to hold its side button to turn it on again.") { manager.shutDown() }
        case .enterRecovery:
            VStack(alignment: .leading, spacing: 12) {
                row("Current mode", firmware.mode.rawValue)
                destructive("Enter Recovery Mode", confirm: "Put the iPhone in recovery mode?", message: "The screen shows the restore symbol. Exit Recovery brings it back without changing anything.",
                            enabled: ready && Tools.has("ideviceenterrecovery")) {
                    Task { if let u = Lockdown.firstUDID() { await firmware.enterRecovery(udid: u) } }
                }
            }
        case .exitRecovery:
            VStack(alignment: .leading, spacing: 12) {
                row("Current mode", firmware.mode.rawValue)
                HStack {
                    Button("Exit Recovery Mode") { Task { await firmware.exitRecovery() } }.disabled(!Tools.has("irecovery") || firmware.running)
                    Button("Check Mode") { Task { await firmware.refreshMode() } }.disabled(firmware.running)
                }
            }
        case .rename:
            HStack(spacing: 8) {
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 280)
                Button("Rename") { manager.rename(newName.trimmingCharacters(in: .whitespaces)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready || newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == manager.device?.name)
            }
        case .identifiers:
            identifiers
        case .report:
            VStack(alignment: .leading, spacing: 12) {
                Button("Save Device Report…") { manager.exportReport() }.buttonStyle(.borderedProminent).disabled(!ready)
                if let u = manager.lastReport {
                    HStack { Text("Saved to \(u.path)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.link).font(.system(size: 12)) }
                }
            }
        case .unpair:
            destructive("Unpair This Mac", confirm: "Unpair this Mac from the iPhone?", message: "Decant and Finder lose access until you tap Trust on the phone again.",
                        enabled: ready && Tools.has("idevicepair")) { manager.unpair() }
        case .crashReports:
            VStack(alignment: .leading, spacing: 12) {
                Button("Copy Crash Reports…") { manager.exportCrashReports() }.buttonStyle(.borderedProminent).disabled(!ready || !Tools.has("idevicecrashreport"))
                if let (dir, n) = manager.lastCrashExport {
                    HStack { Text("\(n) reports in \(dir.path)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }.buttonStyle(.link).font(.system(size: 12)) }
                }
            }
        case .systemLog:
            SyslogView(embedded: true).environmentObject(manager)
                .frame(height: 440)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        case .screenshot:
            VStack(alignment: .leading, spacing: 12) {
                Button("Take Screenshot") { manager.screenshot() }.buttonStyle(.borderedProminent).disabled(!ready || !Tools.has("idevicescreenshot"))
                if let u = manager.lastScreenshot, let img = NSImage(contentsOf: u) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    HStack { Text(u.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.link).font(.system(size: 12)) }
                } else if let e = manager.lastScreenshotError {
                    Text(e).font(.system(size: 12)).foregroundStyle(Tone.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .battery:
            if let b = manager.battery {
                VStack(spacing: 0) {
                    row("Charge", b.level.map { "\($0)%" } ?? "–")
                    row("State", b.charging == true ? "Charging" : b.charging == false ? "On battery" : "–")
                    row("Health", b.health.map { String(format: "%.0f%% of design capacity", $0) } ?? "–")
                    row("Cycle count", b.cycleCount.map { $0.formatted() } ?? "–")
                    row("Design capacity", b.designCapacity.map { "\($0.formatted()) mAh" } ?? "–")
                    row("Current full capacity", b.maxCapacity.map { "\($0.formatted()) mAh" } ?? "–")
                    row("Temperature", b.temperature.map { String(format: "%.1f °C", $0) } ?? "–")
                }
                Text("Apple replaces batteries under warranty below 80% health. Figures refresh every 30 seconds while connected.").font(.caption).foregroundStyle(.secondary)
                BatteryHistoryView(samples: manager.batteryHistory)
            } else {
                Text("Connect an iPhone to read its battery").foregroundStyle(.secondary)
            }
        case .diagnostics:
            DiagnosticsView().environmentObject(manager)
        case .appLog:
            LogView().environmentObject(manager)
                .frame(height: 440)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        case .reread:
            HStack(spacing: 12) {
                Button("Re-read Library") { manager.refresh() }.buttonStyle(.borderedProminent).disabled(manager.device == nil || manager.running)
                Text("\(manager.items.count.formatted()) items · \(DeviceManager.gb(manager.totalBytes))").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func destructive(_ label: String, confirm: String, message: String, enabled: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(label) { confirming = true }
            .disabled(!(enabled ?? ready))
            .alert(confirm, isPresented: $confirming) {
                Button(label, role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: { Text(message) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
            Text(value).fontWeight(.medium).monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var identifierRows: [(String, String)] {
        guard let i = manager.info else { return [] }
        return [("Serial number", i.serial), ("UDID", i.udid), ("ECID", i.ecid), ("IMEI", i.imei), ("IMEI 2", i.imei2),
                ("MEID", i.meid), ("Wi‑Fi address", i.wifiAddress), ("Bluetooth address", i.bluetoothAddress),
                ("Model", i.model), ("Model number", i.modelNumber + i.region), ("Baseband serial", i.basebandSerial)]
            .filter { !$0.1.isEmpty }
    }

    private var identifiers: some View {
        VStack(alignment: .leading, spacing: 12) {
            if identifierRows.isEmpty {
                Text("Connect an iPhone to read its identifiers").foregroundStyle(.secondary)
            } else {
                Toggle("Reveal", isOn: $revealed).toggleStyle(.switch).controlSize(.small)
                VStack(spacing: 0) {
                    ForEach(identifierRows, id: \.0) { label, value in
                        HStack(spacing: 8) {
                            Text(label).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
                            Text(revealed ? value : String(repeating: "•", count: min(value.count, 24))).monospaced().textSelection(.enabled)
                            Spacer()
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless).help("Copy")
                        }
                        .font(.system(size: 13))
                        .frame(height: 32)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                Text("Treat these like passwords: together they identify this exact phone.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - System log, streamed from the phone

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
    var embedded = false

    private var shown: [String] {
        filter.isEmpty ? log.lines : log.lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Toggle("Pause", isOn: $paused).toggleStyle(.checkbox)
                Button("Clear") { log.lines = [] }
                Spacer()
                Text("\(shown.count.formatted()) lines").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button(log.running ? "Stop" : "Start") {
                    if log.running { log.stop() } else if let u = Lockdown.firstUDID() { log.start(udid: u) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.device == nil || !Tools.has("idevicesyslog"))
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
                        if shown.isEmpty {
                            Text(log.running ? "Waiting for log lines…" : "Press Start to stream the phone's log").foregroundStyle(.secondary).padding(8)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: shown.count) { n in
                    if !paused, n > 0 { proxy.scrollTo(min(n, 2000) - 1, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: embedded ? 0 : 720, minHeight: embedded ? 0 : 420)
        .onDisappear { log.stop() }
    }
}

// MARK: - Device-side actions

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
                    self.lastReport = url
                    self.addLog("Device report saved to \(url.path)")
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
            let status = await Tools.stream("idevicecrashreport", ["-u", udid, "-e", dir.path]) { _ in }
            let count = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".ips") || $0.hasSuffix(".crash") }.count
            addLog(status == 0 ? "Crash reports copied: \(count) files" : "Crash report copy failed")
            if status == 0 { lastCrashExport = (dir, count) }
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
                lastScreenshot = url; lastScreenshotError = nil
                addLog("Screenshot saved to \(url.path)")
            } else {
                lastScreenshotError = "Screenshot failed: \(output.trimmingCharacters(in: .whitespaces)). On iOS 17 and later, turn on Developer Mode in Settings → Privacy & Security, then try again."
                addLog(lastScreenshotError!)
            }
        }
    }
}

// MARK: - Battery history: one sample per connection and per hour on the cable, kept per phone

struct BatteryHistoryView: View {
    let samples: [BatterySample]

    private var health: [BatterySample] { samples.filter { $0.health != nil } }
    private var span: String {
        guard let a = samples.first?.date, let b = samples.last?.date else { return "" }
        let days = Int(b.timeIntervalSince(a) / 86400)
        return days < 1 ? "today" : days < 60 ? "\(days) days" : "\(days / 30) months"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(samples.count < 2 ? "Builds up as the phone connects" : "\(samples.count) readings over \(span)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.top, 8)
            if health.count >= 2 {
                HStack(alignment: .top, spacing: 24) {
                    chart("Health", unit: "%", values: health.map { ($0.date, $0.health!) }, domain: healthDomain)
                    chart("Cycles", unit: "", values: health.compactMap { s in s.cycleCount.map { (s.date, Double($0)) } }, domain: nil)
                }
                if let first = health.first?.health, let last = health.last?.health {
                    Text(String(format: "%.0f%% health when Decant first saw this phone, %.0f%% now · %@ cycles",
                                first, last, (health.last?.cycleCount).map { $0.formatted() } ?? "–"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text("Each time the iPhone connects, Decant notes its health and cycle count here. After a few weeks the trend shows whether the battery is ageing normally (about 1% of health per 25 cycles is typical).")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var healthDomain: ClosedRange<Double> {
        let v = health.map { $0.health! }
        return (max(0, (v.min() ?? 80) - 5)).rounded(.down)...min(100, (v.max() ?? 100) + 1)
    }

    /// One quiet line per chart; the latest reading is the only point drawn.
    private func chart(_ title: String, unit: String, values: [(Date, Double)], domain: ClosedRange<Double>?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                if let last = values.last { Text(String(format: unit == "%" ? "%.0f%%" : "%.0f", last.1)).font(.system(size: 12, weight: .medium)).monospacedDigit() }
            }
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    LineMark(x: .value("Date", v.0), y: .value(title, v.1)).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                }
                if let last = values.last {
                    PointMark(x: .value("Date", last.0), y: .value(title, last.1)).foregroundStyle(Color.accentColor).symbolSize(28)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).font(.system(size: 10)) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel().font(.system(size: 10)) } }
            .frame(height: 120)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Diagnostics: the phone's self-tests plus live charging figures

struct DiagnosticsView: View {
    @EnvironmentObject var manager: DeviceManager

    private var gauge: [String: Any] { manager.diagnostics?["GasGauge"] as? [String: Any] ?? [:] }
    private func status(_ key: String) -> String? {
        guard let d = manager.diagnostics?[key] as? [String: Any] else { return nil }
        let st = d["Status"] as? String ?? ""
        if key == "WiFi", let a = d["Active"] as? String { return "\(st == "Success" ? "Passed" : st) · \(a == "YES" ? "active" : "inactive")" }
        if key == "HDMI", let c = d["Connection"] as? String { return c == "No" ? "Nothing connected" : "Connected" }
        return st == "Success" ? "Passed" : st.isEmpty ? nil : st
    }

    var body: some View {
        let b = manager.battery
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Charging").font(.system(size: 13, weight: .medium)).padding(.bottom, 6)
                row("State", b?.charging == true ? "Charging" : b?.externalConnected == true ? "Plugged in, not charging" : b?.charging == false ? "On battery" : "–")
                row("Charger", b?.adapterWatts.map { "\($0) W" + (b?.adapterName.map { " · \($0)" } ?? "") } ?? (b?.externalConnected == false ? "None" : "–"))
                row("Power now", b?.watts.map { abs($0) < 0.05 ? "Idle" : String(format: "%.1f W %@", abs($0), $0 > 0 ? "into the battery" : "from the battery") } ?? "–")
                row("Voltage", b?.voltage.map { String(format: "%.2f V", $0) } ?? "–")
                row("Current", b?.amperage.map { String(format: "%.2f A", $0) } ?? "–")
                row("Temperature", b?.temperature.map { String(format: "%.1f °C", $0) } ?? "–")
            }
            Text("A 20 W charger on a good cable shows 15 to 20 W into the battery below 80%. A few watts means a weak cable, a USB-A port or a hot phone.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Self-tests").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Run Again") { manager.runDiagnostics() }.controlSize(.small).disabled(manager.device == nil || manager.running)
                }
                .padding(.bottom, 6)
                row("Battery gauge", status("GasGauge") ?? "–")
                row("Gauge cycle count", (gauge["CycleCount"] as? Int).map { $0.formatted() } ?? "–")
                row("Gauge full charge", (gauge["FullChargeCapacity"] as? Int).map { "\($0.formatted()) mAh" } ?? "–")
                row("Storage (NAND)", status("NAND") ?? "–")
                row("Wi-Fi", status("WiFi") ?? "–")
                row("Video out", status("HDMI") ?? "–")
            }
            Text(manager.diagnostics == nil ? "The self-tests run when the phone connects." : "These are the checks iOS runs on itself; Decant only asks for the results. Deeper storage or logic-board diagnostics need Apple's tools.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
            Text(value).fontWeight(.medium).monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension DeviceManager {
    func runDiagnostics() {
        guard let udid = Lockdown.cachedUDID else { return }
        if Demo.on { diagnostics = Demo.diagnostics(); addLog("Self-tests passed"); return }
        addLog("Running the phone's self-tests")
        Task.detached { [weak self] in
            let d = Lockdown.plist("idevicediagnostics", ["-u", udid, "diagnostics", "All"])
            await MainActor.run { self?.diagnostics = d; self?.addLog(d == nil ? "Self-tests did not answer" : "Self-tests finished") }
        }
    }
}
