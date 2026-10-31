import SwiftUI

// MARK: - Backup & Restore

/// Opens one backup for browsing: counts what it holds, unlocks an encrypted one, exports readable files.
@MainActor
final class BackupBrowserModel: ObservableObject {
    @Published var backup: BackupInfo?
    @Published var summary: BackupSummary?
    @Published var needsPassword = false
    @Published var error: String?
    @Published var busy = false
    @Published var phase = ""
    @Published var lastExport: (URL, Int)?
    private var reader: BackupReader?

    func open(_ b: BackupInfo) {
        guard b != backup else { return }
        close()
        backup = b; summary = nil; error = nil; needsPassword = false; lastExport = nil
        if Demo.on { summary = Demo.summary(); return }
        busy = true; phase = "Reading the backup"
        Task.detached { [folder = b.url] in
            do {
                let r = try BackupReader(folder: folder)
                let s = r.isUnlocked ? try r.summary() : nil
                await MainActor.run { self.reader = r; self.summary = s; self.needsPassword = !r.isUnlocked; self.busy = false; self.phase = "" }
            } catch {
                await MainActor.run { self.error = "\(error)"; self.busy = false; self.phase = "" }
            }
        }
    }

    func unlock(_ password: String) {
        guard let r = reader, !password.isEmpty else { return }
        busy = true; phase = "Unlocking"; error = nil
        Task.detached {
            do {
                try r.unlock(password: password)
                let s = try r.summary()
                await MainActor.run { self.summary = s; self.needsPassword = false; self.busy = false; self.phase = "" }
            } catch {
                await MainActor.run { self.error = "\(error)"; self.busy = false; self.phase = "" }
            }
        }
    }

    func export(_ kinds: [BackupExport], to folder: URL, log: @escaping (String) -> Void) {
        busy = true; phase = "Exporting"; error = nil; lastExport = nil
        if Demo.on {
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); lastExport = (folder, kinds.count * 120); busy = false; phase = "" }
            return
        }
        guard let r = reader else { busy = false; return }
        Task.detached {
            do {
                let counts = try r.export(kinds, to: folder) { p in Task { @MainActor in self.phase = p } }
                let total = counts.values.reduce(0, +)
                await MainActor.run {
                    self.lastExport = (folder, total); self.busy = false; self.phase = ""
                    log("Exported \(counts.map { "\($0.key.title) \($0.value)" }.sorted().joined(separator: ", ")) to \(folder.path)")
                }
            } catch {
                await MainActor.run { self.error = "\(error)"; self.busy = false; self.phase = "" }
            }
        }
    }

    func close() { reader?.close(); reader = nil; backup = nil; summary = nil }
}

struct BackupPane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var backups: BackupService
    @StateObject private var browser = BackupBrowserModel()
    @AppStorage("backupRoot") private var backupRoot = BackupService.defaultRoot.path
    @AppStorage("lastUDID") private var lastUDID = ""
    @State private var selection: String? = "phone"
    @State private var restoring: BackupInfo?
    @State private var restoreConfirmed = false
    @State private var restorePassword = ""
    @State private var deleting: BackupInfo?
    @State private var badFolder = false
    @State private var passwordSheet: PasswordSheet.Mode?
    @State private var unlockPassword = ""
    let showLog: () -> Void

    private var root: URL { URL(fileURLWithPath: backupRoot) }
    private var usbUDID: String { manager.device != nil ? (Lockdown.cachedUDID ?? "") : "" }
    /// The phone over Wi-Fi when there is no cable: the last phone seen here, if usbmuxd lists it on the network.
    private var wifiUDID: String? {
        guard manager.device == nil else { return nil }
        return manager.networkUDIDs.first { $0 == lastUDID } ?? (lastUDID.isEmpty ? manager.networkUDIDs.first : nil)
    }
    private var udid: String { usbUDID.isEmpty ? (wifiUDID ?? "") : usbUDID }
    private var overWifi: Bool { usbUDID.isEmpty && wifiUDID != nil }
    private var ready: Bool { !udid.isEmpty && Lockdown.available && !backups.running }
    private var selectedBackup: BackupInfo? { (backups.backups + backups.finderBackups).first { $0.id == selection } }
    private var latest: BackupInfo? { (backups.backups + backups.finderBackups).max { $0.date < $1.date } }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Device") {
                    HStack(spacing: 8) {
                        Image(systemName: overWifi ? "wifi" : "iphone").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                        Text(manager.device?.name ?? (overWifi ? "iPhone over Wi-Fi" : "This iPhone"))
                        Spacer()
                    }
                    .frame(height: 24).tag("phone")
                }
                Section("Decant backups") {
                    if backups.backups.isEmpty {
                        Text("None yet").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(backups.backups) { b in sidebarRow(b).tag(b.id) }
                }
                Section("Finder backups") {
                    if !backups.finderBackupsReadable {
                        Text("Needs Full Disk Access").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if backups.finderBackups.isEmpty {
                        Text("None on this Mac").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(backups.finderBackups) { b in sidebarRow(b).tag(b.id) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 240)
            Divider()
            Group {
                if let b = selectedBackup { backupDetail(b) } else { phoneDetail }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            backups.log = { [weak manager] in manager?.addLog($0) }
            backups.scan(root)
            rememberPhone()
            if let sel = ProcessInfo.processInfo.environment["DECANT_SELECT"], sel.hasPrefix("backup:"), let n = Int(sel.dropFirst(7)),   // screenshot aid
               backups.backups.indices.contains(n) { selection = backups.backups[n].id }
        }
        .onChange(of: manager.catalogComplete) { _ in rememberPhone() }
        .onChange(of: selection) { _ in if let b = selectedBackup { browser.open(b); unlockPassword = "" } }
        .sheet(item: $passwordSheet) { mode in
            PasswordSheet(mode: mode) { current, new in
                Task {
                    switch mode {
                    case .turnOn: _ = await backups.setEncryption(on: true, password: new, udid: udid)
                    case .turnOff: _ = await backups.setEncryption(on: false, password: current, udid: udid)
                    case .change: _ = await backups.changePassword(old: current, new: new, udid: udid)
                    }
                }
            }
        }
        .alert("Restore this backup?", isPresented: Binding(get: { restoring != nil && !restoreConfirmed }, set: { if !$0 { restoring = nil } })) {
            Button("Continue", role: .destructive) { restoreConfirmed = true }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            if let r = restoring {
                Text("\(r.deviceName), iOS \(r.version), \(r.date.formatted(date: .abbreviated, time: .shortened)). Everything currently on the iPhone will be replaced.")
            }
        }
        .alert("Last check", isPresented: $restoreConfirmed) {
            if restoring?.encrypted == true { SecureField("Backup password", text: $restorePassword) }
            Button("Restore and Reboot", role: .destructive) {
                if let r = restoring { Task { await backups.restore(r, udid: udid, password: r.encrypted ? restorePassword : nil) } }
                restoring = nil; restorePassword = ""
            }
            .disabled(restoring?.encrypted == true && restorePassword.isEmpty)
            Button("Cancel", role: .cancel) { restoring = nil; restorePassword = "" }
        } message: {
            Text(restoring?.encrypted == true ? "This backup is encrypted. Enter its password to continue." : "The iPhone will restart when the restore finishes.")
        }
        .alert("That folder is not an iPhone backup", isPresented: $badFolder) {
            Button("OK") {}
        } message: { Text("Pick the backup folder itself (it contains Info.plist and Manifest.plist) or the folder that holds it.") }
        .alert("Move this backup to the Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) { if let d = deleting { backups.delete(d, root: root); selection = "phone" } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(deleting.map { "\($0.deviceName), \($0.date.formatted(date: .abbreviated, time: .shortened)), \(DeviceManager.gb($0.size))" } ?? "") }
    }

    /// Remember the phone that was on the cable so a later Wi-Fi backup knows which network device is ours.
    private func rememberPhone() {
        if !usbUDID.isEmpty { lastUDID = usbUDID }
        if !udid.isEmpty, backups.settingsFor != udid { Task { await backups.readSettings(udid: udid) } }
    }

    private func sidebarRow(_ b: BackupInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.encrypted ? "lock" : "externaldrive").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.deviceName).lineLimit(1)
                Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text(DeviceManager.gb(b.size)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(height: 32)
    }

    // MARK: Device page: status, destination, encryption and Wi-Fi settings, the primary action, what a backup holds

    private var phoneDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.device?.name ?? (overWifi ? "iPhone over Wi-Fi" : "No iPhone")).font(.system(size: 20, weight: .semibold))
                    Text(latest.map { "Last backed up \($0.date.formatted(.relative(presentation: .named))) · \(DeviceManager.gb($0.size))" }
                         ?? (udid.isEmpty ? manager.statusText : "Never backed up with this Mac"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        label("Backups go to")
                        HStack(spacing: 8) {
                            Text(DeviceDashboard.shortPath(root)).lineLimit(1).truncationMode(.middle)
                            Button("Change…", action: chooseRoot).buttonStyle(.link)
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }.buttonStyle(.link)
                            Text(DeviceManager.freeSpace(at: root).map { "\(DeviceManager.gb($0)) free" } ?? "").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .frame(height: 32)
                    GridRow {
                        label("Size on iPhone")
                        Text(manager.storage.map { DeviceManager.gb($0.capacity - $0.free) + " used" } ?? "–").monospacedDigit()
                    }
                    .frame(height: 32)
                    GridRow {
                        label("Connection")
                        Text(manager.device != nil ? (manager.networkUDIDs.contains(usbUDID) ? "USB · also reachable over Wi-Fi" : "USB") : overWifi ? "Wi-Fi, no cable" : "–")
                    }
                    .frame(height: 32)
                    GridRow {
                        label("Encryption")
                        settingRow(state: backups.willEncrypt,
                                   on: "On · Health, passwords and Wi-Fi included",
                                   off: "Off · Health, passwords and Wi-Fi left out") {
                            if backups.willEncrypt == true {
                                Button("Change Password…") { passwordSheet = .change }
                                Button("Turn Off…") { passwordSheet = .turnOff }
                            } else {
                                Button("Turn On…") { passwordSheet = .turnOn }
                            }
                        }
                    }
                    .frame(height: 32)
                    GridRow {
                        label("Wi-Fi backups")
                        settingRow(state: backups.wifiSync,
                                   on: manager.networkUDIDs.contains(where: { $0 == udid }) ? "On · reachable on this network now" : "On · backs up without the cable on this network",
                                   off: "Off · a cable is needed to back up") {
                            Button(backups.wifiSync == true ? "Turn Off" : "Turn On") { Task { _ = await backups.setWifiSync(backups.wifiSync != true, udid: udid) } }
                                .disabled(usbUDID.isEmpty)
                                .help(usbUDID.isEmpty ? "Connect the cable to change this" : "")
                        }
                    }
                    .frame(height: 32)
                }
                .font(.system(size: 13))
                .disabled(backups.running)

                if backups.running {
                    HStack(spacing: 12) {
                        ProgressView(value: backups.progress ?? 0).frame(maxWidth: 360).opacity(backups.progress == nil ? 0 : 1)
                            .overlay { if backups.progress == nil { ProgressView().controlSize(.small) } }
                        Text("\(backups.phase) \(backups.progress.map { "\(Int($0 * 100))%" } ?? "")").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Stop") { backups.cancel() }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button(overWifi ? "Back Up Now over Wi-Fi" : "Back Up Now") {
                            Task { await backups.backup(udid: udid, to: root, network: overWifi) }
                        }
                        .buttonStyle(.borderedProminent).disabled(!ready)
                        Button("Restore from Folder…", action: restoreFromFolder).disabled(!ready || overWifi)
                        if !backups.phase.isEmpty { Text(backups.phase).font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 8) }
                    }
                    .controlSize(.large)
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("What a backup holds").font(.system(size: 13, weight: .medium))
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow { include("Messages, call history, notes, voice memos") ; include("App data and documents") }
                        GridRow { include("Home screen layout and settings") ; include("Photos and videos, unless iCloud Photos keeps them") }
                        GridRow { include("Health, passwords, Wi-Fi: encrypted backups only") ; include("Not included: apps themselves, Face ID, Apple Pay cards") }
                    }
                    .font(.system(size: 12))
                    Text("Select a backup on the left to read its messages, contacts, call history, notes, voice memos, Safari history and WhatsApp chats, or to export them as files. A restore replaces everything on the iPhone with the backup and reboots it; Decant asks twice and never restores on its own.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
                }
                if !backups.finderBackupsReadable {
                    Divider()
                    HStack(spacing: 12) {
                        Text("Decant needs Full Disk Access to list backups made with Finder or iTunes.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }.controlSize(.small)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    /// A setting's state in words, then the one or two buttons that change it.
    private func settingRow<B: View>(state: Bool?, on: String, off: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 12) {
            Circle().fill(state == true ? Tone.ready : Color(nsColor: .tertiaryLabelColor)).frame(width: 7, height: 7)
            Text(state == nil ? (udid.isEmpty ? "–" : "Reading…") : state == true ? on : off).lineLimit(1).truncationMode(.tail)
            if state != nil { HStack(spacing: 8, content: buttons).controlSize(.small).disabled(udid.isEmpty) }
        }
    }

    private func include(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(.tertiary).frame(width: 4, height: 4).offset(y: -3)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Backup page: details, actions, and what is inside

    private func backupDetail(_ b: BackupInfo) -> some View {
        let isDecant = backups.backups.contains(b)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(b.deviceName).font(.system(size: 20, weight: .semibold))
                    Text(b.date.formatted(date: .complete, time: .shortened)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
                    detailRow("iOS version", b.version)
                    detailRow("Size", DeviceManager.gb(b.size))
                    detailRow("Encrypted", b.encrypted ? "Yes" : "No")
                    detailRow("Made with", isDecant ? "Decant" : "Finder or iTunes")
                    GridRow {
                        label("Location")
                        HStack(spacing: 8) {
                            Text(DeviceDashboard.shortPath(b.url)).lineLimit(1).truncationMode(.middle)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }.buttonStyle(.link)
                        }
                    }
                    .frame(height: 32)
                }
                .font(.system(size: 13))
                HStack(spacing: 8) {
                    Button("Restore to iPhone…") { restoring = b }.disabled(!ready || overWifi)
                    if isDecant { Button("Move to Trash…") { deleting = b }.disabled(backups.running) }
                }
                .controlSize(.large)
                Text(ready && !overWifi ? "Restoring puts this backup on \(manager.device?.name ?? "the connected iPhone") and reboots it."
                           : "Connect and unlock an iPhone over USB to restore this backup.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                contents(b)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .onAppear { browser.open(b) }
    }

    /// What the backup holds, by kind, each exportable on its own or all at once.
    @ViewBuilder private func contents(_ b: BackupInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Contents").font(.system(size: 13, weight: .medium))
                Spacer()
                if browser.summary != nil {
                    Button("Export All…") { chooseExport(BackupExport.allCases, from: b) }.controlSize(.small).disabled(browser.busy)
                }
            }
            if browser.needsPassword {
                HStack(spacing: 8) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    SecureField("Backup password", text: $unlockPassword).textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit { browser.unlock(unlockPassword) }
                    Button("Unlock") { browser.unlock(unlockPassword) }.disabled(unlockPassword.isEmpty || browser.busy)
                    if browser.busy { ProgressView().controlSize(.small) }
                }
                Text("This backup is encrypted. The password stays on this Mac for as long as the backup is open and is not stored.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let s = browser.summary {
                VStack(spacing: 0) {
                    ForEach(BackupExport.allCases) { kind in
                        contentRow(kind, s, from: b)
                    }
                }
                Text("Exports are plain files: HTML and text for conversations, vCard for contacts, CSV for calls and history, the original audio for voice memos. Nothing is sent anywhere.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if browser.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(browser.phase).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            if browser.busy && browser.summary != nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(browser.phase).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let (dir, n) = browser.lastExport {
                HStack(spacing: 8) {
                    Text("\(n.formatted()) items exported to \(DeviceDashboard.shortPath(dir))").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            if let e = browser.error {
                Text(e).font(.system(size: 12)).foregroundStyle(Tone.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func contentRow(_ kind: BackupExport, _ s: BackupSummary, from b: BackupInfo) -> some View {
        let (count, detail) = describe(kind, s)
        return HStack(spacing: 12) {
            Image(systemName: kind.symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 24)
            Text(kind.title).font(.system(size: 13, weight: .medium)).frame(width: 128, alignment: .leading)
            Text(count == 0 ? "None" : detail).font(.system(size: 13)).foregroundStyle(count == 0 ? .tertiary : .secondary).monospacedDigit()
            Spacer()
            Button("Export…") { chooseExport([kind], from: b) }.controlSize(.small).disabled(count == 0 || browser.busy)
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 36) }
    }

    private func describe(_ kind: BackupExport, _ s: BackupSummary) -> (Int, String) {
        func n(_ v: Int, _ one: String, _ many: String) -> String { "\(v.formatted()) \(v == 1 ? one : many)" }
        switch kind {
        case .messages: return (s.messages, "\(n(s.messages, "message", "messages")) in \(n(s.conversations, "conversation", "conversations"))")
        case .contacts: return (s.contacts, n(s.contacts, "contact", "contacts"))
        case .calls: return (s.calls, n(s.calls, "call", "calls"))
        case .notes: return (s.notes, n(s.notes, "note", "notes"))
        case .voiceMemos: return (s.voiceMemos, n(s.voiceMemos, "recording", "recordings"))
        case .safari: return (s.safariHistory, n(s.safariHistory, "page visit", "page visits"))
        case .whatsapp: return (s.whatsappMessages, s.whatsappChats == 0 ? "" : "\(n(s.whatsappMessages, "message", "messages")) in \(n(s.whatsappChats, "chat", "chats"))")
        }
    }

    private func chooseExport(_ kinds: [BackupExport], from b: BackupInfo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = kinds.count == 1 ? "Choose a folder for the \(kinds[0].title.lowercased()) export" : "Choose a folder for the export"
        panel.directoryURL = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("Decant")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let target = dir.appendingPathComponent("\(b.deviceName) \(f.string(from: b.date))")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        browser.export(kinds, to: target) { [weak manager] in manager?.addLog($0) }
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        GridRow { label(k); Text(v).monospacedDigit() }.frame(height: 32)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
    }

    private func restoreFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use this backup"
        panel.message = "Choose an iPhone backup folder (Decant, Finder or iTunes)"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        if let info = backups.info(for: u) { restoring = info } else { badFolder = true }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = root
        if panel.runModal() == .OK, let u = panel.url { backupRoot = u.path; backups.scan(u) }
    }
}

/// Setting, removing or changing the backup password. The phone asks for its passcode when the setting changes.
struct PasswordSheet: View {
    enum Mode: String, Identifiable { case turnOn, turnOff, change; var id: String { rawValue } }
    let mode: Mode
    let done: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""

    private var title: String {
        switch mode { case .turnOn: return "Turn On Backup Encryption"; case .turnOff: return "Turn Off Backup Encryption"; case .change: return "Change Backup Password" }
    }
    private var valid: Bool {
        switch mode {
        case .turnOn: return !new.isEmpty && new == confirm
        case .turnOff: return !current.isEmpty
        case .change: return !current.isEmpty && !new.isEmpty && new == confirm
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(mode == .turnOff ? "Future backups leave out Health data, saved passwords and Wi-Fi settings. Existing encrypted backups keep their password."
                     : "Encrypted backups include Health data, saved passwords and Wi-Fi settings. Apple cannot recover a forgotten backup password; write it down.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                if mode != .turnOn {
                    GridRow { Text("Current password").foregroundStyle(.secondary); SecureField("", text: $current).textFieldStyle(.roundedBorder).frame(width: 260) }
                }
                if mode != .turnOff {
                    GridRow { Text(mode == .change ? "New password" : "Password").foregroundStyle(.secondary); SecureField("", text: $new).textFieldStyle(.roundedBorder).frame(width: 260) }
                    GridRow { Text("Verify").foregroundStyle(.secondary); SecureField("", text: $confirm).textFieldStyle(.roundedBorder).frame(width: 260) }
                }
            }
            .font(.system(size: 13))
            if mode != .turnOff && !confirm.isEmpty && new != confirm {
                Text("The passwords do not match").font(.system(size: 12)).foregroundStyle(Tone.warning)
            }
            Text("The iPhone asks for its passcode to confirm.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .turnOff ? "Turn Off" : mode == .change ? "Change" : "Turn On") { done(current, new); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

// MARK: - Firmware

struct FirmwarePane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var firmware: FirmwareService
    @AppStorage("firmwareRoot") private var firmwareRoot = FirmwareService.defaultRoot.path
    @AppStorage("autoSaveBlobs") private var autoSaveBlobs = true
    private let generator = FirmwareService.generator                  // the convention; not user-editable
    @AppStorage("extraGenerator") private var extraGenerator = ""       // advanced: a second generator, saved in addition
    @State private var editingExtra = false
    @State private var extraDraft = ""
    @State private var restoreTarget: (fw: Firmware, erase: Bool, future: Bool)?
    @State private var confirmStep = 0
    @State private var revealECID = false
    let showLog: () -> Void

    private var root: URL { URL(fileURLWithPath: firmwareRoot) }
    private var ecid: String { manager.info?.ecid ?? "" }
    private var board: String { manager.info?.hardware ?? "" }
    private var model: String { manager.info?.model ?? "" }
    private var connected: Bool { manager.device != nil && !ecid.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                blobsSection
                firmwareSection
                recoveryRow
                Text("Signed versions can be restored or updated any time. An unsigned version needs a blob saved for it, and the phone's nonce set to the blob's generator (\(FirmwareService.generator)), which on A12 and newer chips only a jailbreak can do. Decant saves blobs with that generator so the restore is possible later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            firmware.log = { [weak manager] in manager?.addLog($0) }
            refresh()
        }
        .onChange(of: manager.info?.model) { _ in refresh() }
        .alert(firstTitle, isPresented: Binding(get: { restoreTarget != nil && confirmStep == 1 }, set: { if !$0 { restoreTarget = nil; confirmStep = 0 } })) {
            Button("Continue", role: .destructive) { confirmStep = 2 }
            Button("Cancel", role: .cancel) { restoreTarget = nil; confirmStep = 0 }
        } message: { Text(firstMessage) }
        .alert("Last check", isPresented: Binding(get: { restoreTarget != nil && confirmStep == 2 }, set: { if !$0 { restoreTarget = nil; confirmStep = 0 } })) {
            Button(restoreTarget?.erase == true ? "Erase and Restore" : "Update", role: .destructive) { runRestore() }
            Button("Cancel", role: .cancel) { restoreTarget = nil; confirmStep = 0 }
        } message: { Text("Keep the cable connected until the iPhone finishes and shows the Hello screen or your lock screen.") }
    }

    /// The default generator always; a custom one only in addition, never instead.
    private func saveAll() async {
        let bb = (manager.info?.basebandSerial ?? "", manager.info?.basebandCert ?? "")
        await firmware.saveBlobs(ecid: ecid, productType: model, board: board, basebandSerial: bb.0, basebandCert: bb.1, root: root, generator: generator)
        if FirmwareService.validGenerator(extraGenerator) && extraGenerator != generator {
            await firmware.saveBlobs(ecid: ecid, productType: model, board: board, basebandSerial: bb.0, basebandCert: bb.1, root: root, generator: extraGenerator)
        }
    }

    private func refresh() {
        guard !model.isEmpty else { return }
        Task {
            await firmware.loadSigning(productType: model)
            firmware.scanBlobs(root: root, ecid: ecid)
            await firmware.refreshMode()
            if autoSaveBlobs && !ecid.isEmpty && !board.isEmpty && Tools.has("decant-tss") {
                await saveAll()
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(connected ? "iOS \(manager.info?.version ?? "–")" : "No iPhone connected").font(.system(size: 22, weight: .medium))
                    if connected { Text("\(manager.info?.marketingName ?? "") · \(model) · \(board)").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 0) {
                    GridRow {
                        infoRow("ECID") {
                            if connected {
                                Text(revealECID ? ecid : String(repeating: "•", count: max(ecid.count, 8))).monospaced()
                                Button { revealECID.toggle() } label: { Image(systemName: revealECID ? "eye.slash" : "eye").font(.system(size: 12)).foregroundStyle(.secondary) }.buttonStyle(.borderless)
                            } else { Text("–") }
                        }
                        infoRow("Mode") { Text(connected ? firmware.mode.rawValue : "–") }
                    }
                    GridRow {
                        infoRow("Signed now") { Text(firmware.firmwares.filter { firmware.isSigned($0) }.map { $0.version }.joined(separator: ", ")).lineLimit(1) }
                        infoRow("Blobs saved") { Text(connected ? "\(firmware.blobs.count)" : "–").monospacedDigit() }
                    }
                }
                HStack {
                    Toggle("Save blobs automatically when the iPhone connects", isOn: $autoSaveBlobs)
                    Spacer()
                    Text("Files go to \(DeviceDashboard.shortPath(root))").foregroundStyle(.secondary)
                    Button("Change…", action: chooseRoot).buttonStyle(.link)
                }
                .font(.system(size: 13))
                HStack(spacing: 8) {
                    Text("Generator").foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                    Text(generator).monospaced()
                    Text("The convention every guide and tool uses").foregroundStyle(.secondary)
                    Spacer()
                    if extraGenerator.isEmpty {
                        Button("Also save for a custom generator…") { extraDraft = ""; editingExtra = true }.buttonStyle(.link)
                    } else {
                        Text("also \(extraGenerator)").monospaced().foregroundStyle(.secondary)
                        Button("Remove") { extraGenerator = "" }.buttonStyle(.link)
                    }
                }
                .alert("Save blobs for a second generator", isPresented: $editingExtra) {
                    TextField("0x…", text: $extraDraft)
                    Button("Add") { extraGenerator = extraDraft.trimmingCharacters(in: .whitespaces) }
                        .disabled(!FirmwareService.validGenerator(extraDraft.trimmingCharacters(in: .whitespaces)))
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Only for a jailbroken phone that already boots with a fixed custom generator. Blobs for the default generator are still saved; a blob for a generator the phone cannot be set to is useless.")
                }
                .font(.system(size: 13))
                if firmware.running {
                    HStack(spacing: 12) {
                        ProgressView(value: firmware.progress ?? 0).frame(maxWidth: 360).opacity(firmware.progress == nil ? 0 : 1)
                            .overlay { if firmware.progress == nil { ProgressView().controlSize(.small) } }
                        Text(firmware.phase).font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { firmware.cancel() }
                    }
                }
            }
        }
    }

    private func infoRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            content().fontWeight(.medium)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var blobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHSH blobs").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button("Save Blobs Now") { Task { await saveAll() } }
                    .controlSize(.small).disabled(!connected || firmware.running || !Tools.has("decant-tss"))
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([FirmwareService.blobDir(root, ecid: ecid)]) }
                    .controlSize(.small).disabled(!connected)
            }
            Text("Saved blobs are never replaced or deleted by Decant: Save Blobs Now only adds versions that are missing, and each file is locked read-only on disk.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                if !Tools.has("decant-tss") {
                    Text("This build has no blob saver").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                } else if firmware.blobs.isEmpty {
                    Text(connected ? "No blobs saved for this iPhone yet" : "Connect an iPhone").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(firmware.blobs.enumerated()), id: \.element.id) { i, b in
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.seal").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 24)
                                Text("iOS \(b.version) (\(b.build))").font(.system(size: 13, weight: .medium))
                                Text(b.generator.map { "generator \($0)" } ?? "no generator").font(.system(size: 12)).foregroundStyle(.secondary).monospaced()
                                Spacer()
                                Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).frame(height: 40)
                            .overlay(alignment: .bottom) { if i < firmware.blobs.count - 1 { Divider().padding(.leading, 44) } }
                        }
                    }
                    .padding(-8)
                }
            }
        }
    }

    private var firmwareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Firmware for \(manager.info?.marketingName ?? "this model")").font(.system(size: 13)).foregroundStyle(.secondary)
            Card {
                if firmware.firmwares.isEmpty {
                    Text(connected ? "Loading signing status…" : "Connect an iPhone").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(firmware.firmwares.prefix(12).enumerated()), id: \.element.id) { i, fw in
                            firmwareRow(fw, last: i == min(firmware.firmwares.count, 12) - 1)
                        }
                    }
                    .padding(-8)
                }
            }
        }
    }

    private func ipswPath(_ fw: Firmware) -> URL? {
        let u = FirmwareService.ipswDir(root).appendingPathComponent(fw.url.lastPathComponent)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func blob(for fw: Firmware) -> BlobInfo? { firmware.blobs.first { $0.build == fw.buildid } }

    private func firmwareRow(_ fw: Firmware, last: Bool) -> some View {
        let downloaded = ipswPath(fw) != nil
        let hasBlob = blob(for: fw) != nil
        let current = fw.version == manager.info?.version
        let signed = firmware.isSigned(fw)
        return HStack(spacing: 12) {
            Circle().fill(signed ? Tone.ready : Color(nsColor: .tertiaryLabelColor)).frame(width: 7, height: 7).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("iOS \(fw.version)").font(.system(size: 13, weight: .medium))
                    if current { Text("installed").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Text("\(fw.buildid) · \(DeviceManager.gb(fw.filesize)) · \(fw.releasedate.prefix(10)) · \(signed ? "signed" : "unsigned")\(hasBlob ? " · blob saved" : "")")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if downloaded {
                Text("downloaded").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button("Download") { Task { _ = await firmware.downloadIPSW(fw, root: root) } }.disabled(firmware.running)
            }
            if signed {
                Button("Update…") { restoreTarget = (fw, false, false); confirmStep = 1 }.disabled(!connected || !downloaded || firmware.running || !Tools.has("idevicerestore"))
                Button("Restore…") { restoreTarget = (fw, true, false); confirmStep = 1 }.disabled(!connected || !downloaded || firmware.running || !Tools.has("idevicerestore"))
            } else {
                Button("Future Restore…") { restoreTarget = (fw, true, true); confirmStep = 1 }
                    .disabled(!connected || !downloaded || !hasBlob || firmware.running || !Tools.has("futurerestore"))
                    .help(hasBlob ? "Needs the phone's nonce set to the blob's generator" : "No blob saved for this version")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 56)
        .overlay(alignment: .bottom) { if !last { Divider().padding(.leading, 44) } }
    }

    private var recoveryRow: some View {
        HStack(spacing: 8) {
            Text("Recovery").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            Text("Mode: \(connected || firmware.mode != .none ? firmware.mode.rawValue : "–")").font(.system(size: 13))
            Button("Enter Recovery…") { Task { if let u = Lockdown.firstUDID() { await firmware.enterRecovery(udid: u) } } }
                .disabled(!connected || firmware.running || !Tools.has("ideviceenterrecovery"))
            Button("Exit Recovery") { Task { await firmware.exitRecovery() } }
                .disabled(firmware.running || !Tools.has("irecovery"))
            Button("Check") { Task { await firmware.refreshMode() } }.disabled(firmware.running)
            Spacer()
            Button("Show Log", action: showLog)
        }
        .controlSize(.small)
    }

    private var firstTitle: String {
        guard let t = restoreTarget else { return "" }
        return t.future ? "Restore to unsigned iOS \(t.fw.version)?" : t.erase ? "Erase and restore to iOS \(t.fw.version)?" : "Update to iOS \(t.fw.version)?"
    }

    private var firstMessage: String {
        guard let t = restoreTarget else { return "" }
        if t.future { return "futurerestore will use your saved blob with the latest signed SEP and baseband. The phone's nonce must already match the blob's generator or it will fail with APNonce mismatch. All data is erased." }
        return t.erase ? "All data on the iPhone is erased. Make a backup first if you have not." : "Your data stays; the system is replaced with iOS \(t.fw.version)."
    }

    private func runRestore() {
        guard let t = restoreTarget, let ipsw = ipswPath(t.fw) else { restoreTarget = nil; confirmStep = 0; return }
        restoreTarget = nil; confirmStep = 0
        Task {
            if t.future, let b = blob(for: t.fw) { await firmware.futureRestore(blob: b.url, ipsw: ipsw, erase: true) }
            else { await firmware.restore(ipsw: ipsw, erase: t.erase) }
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = root
        if panel.runModal() == .OK, let u = panel.url { firmwareRoot = u.path; firmware.scanBlobs(root: u, ecid: ecid) }
    }
}
